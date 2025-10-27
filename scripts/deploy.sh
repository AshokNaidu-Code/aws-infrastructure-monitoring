#!/bin/bash
# Deployment Script for AWS Infrastructure Monitoring
# File: scripts/deploy.sh

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT="prod"
REGION="us-east-1"
VALIDATE_ONLY=false
SKIP_TESTS=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -e, --environment    Environment name (dev/staging/prod) [default: prod]"
            echo "  -r, --region         AWS region [default: us-east-1]"
            echo "  --validate-only      Only validate templates, don't deploy"
            echo "  --skip-tests         Skip running tests"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is not installed"
        exit 1
    fi
    
    # Check if cfn-lint is available
    if ! command -v cfn-lint &> /dev/null; then
        log_warning "cfn-lint not found, installing..."
        pip install cfn-lint
    fi
    
    log_success "Prerequisites check completed"
}

validate_templates() {
    log_info "Validating CloudFormation templates..."
    
    # Validate main stack
    log_info "Validating main-stack.yaml..."
    aws cloudformation validate-template \
        --template-body file://cloudformation/main-stack.yaml \
        --region $REGION > /dev/null
    
    # Validate monitoring stack
    log_info "Validating monitoring-stack.yaml..."
    aws cloudformation validate-template \
        --template-body file://cloudformation/monitoring-stack.yaml \
        --region $REGION > /dev/null
    
    # Run cfn-lint
    log_info "Running cfn-lint..."
    cfn-lint cloudformation/*.yaml
    
    log_success "Template validation completed"
}

run_tests() {
    if [ "$SKIP_TESTS" = true ]; then
        log_info "Skipping tests as requested"
        return
    fi
    
    log_info "Running tests..."
    
    # Check if pytest is available
    if ! command -v pytest &> /dev/null; then
        log_warning "pytest not found, installing..."
        pip install pytest boto3 moto
    fi
    
    # Run Python tests for Lambda functions
    if [ -d "tests" ]; then
        pytest tests/ -v
        log_success "Tests completed"
    else
        log_warning "No tests directory found, skipping tests"
    fi
}

create_s3_bucket() {
    local bucket_name="aws-monitoring-deployment-${ENVIRONMENT}-$(date +%s)"
    
    log_info "Creating S3 bucket for deployment artifacts: $bucket_name"
    
    # Create bucket
    if [ "$REGION" = "us-east-1" ]; then
        aws s3 mb s3://$bucket_name --region $REGION
    else
        aws s3 mb s3://$bucket_name --region $REGION --create-bucket-configuration LocationConstraint=$REGION
    fi
    
    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket $bucket_name \
        --versioning-configuration Status=Enabled \
        --region $REGION
    
    echo $bucket_name
}

package_lambda_functions() {
    local s3_bucket=$1
    
    log_info "Packaging Lambda functions..."
    
    # Create temporary directory for packaging
    mkdir -p temp/lambda-packages
    
    # Package incident response function
    if [ -f "lambda-functions/incident-response.py" ]; then
        log_info "Packaging incident-response function..."
        cd temp/lambda-packages
        cp ../../lambda-functions/incident-response.py lambda_function.py
        
        # Create requirements.txt if it doesn't exist
        if [ ! -f "../../lambda-functions/requirements.txt" ]; then
            echo "boto3>=1.26.0" > requirements.txt
        else
            cp ../../lambda-functions/requirements.txt .
        fi
        
        # Install dependencies
        pip install -r requirements.txt -t .
        
        # Create zip file
        zip -r incident-response.zip .
        
        # Upload to S3
        aws s3 cp incident-response.zip s3://$s3_bucket/lambda/incident-response.zip --region $REGION
        
        # Clean up
        rm -rf *
        cd ../../
        
        log_success "Incident response function packaged and uploaded"
    fi
    
    # Clean up temp directory
    rm -rf temp/lambda-packages
}

deploy_infrastructure() {
    local s3_bucket=$1
    
    log_info "Deploying infrastructure stack..."
    
    # Check if parameter file exists
    local param_file="cloudformation/parameters/${ENVIRONMENT}-params.json"
    if [ ! -f "$param_file" ]; then
        log_warning "Parameter file not found: $param_file"
        log_info "Creating default parameter file..."
        
        # Create parameters directory if it doesn't exist
        mkdir -p cloudformation/parameters
        
        # Create default parameters
        cat > "$param_file" << EOF
[
  {
    "ParameterKey": "Environment",
    "ParameterValue": "$ENVIRONMENT"
  },
  {
    "ParameterKey": "InstanceType",
    "ParameterValue": "t3.micro"
  },
  {
    "ParameterKey": "DBInstanceClass",
    "ParameterValue": "db.t3.micro"
  }
]
EOF
        log_success "Default parameter file created"
    fi
    
    # Deploy main infrastructure stack
    local stack_name="aws-monitoring-${ENVIRONMENT}-main"
    
    log_info "Deploying stack: $stack_name"
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name $stack_name --region $REGION &> /dev/null; then
        log_info "Stack exists, updating..."
        aws cloudformation update-stack \
            --stack-name $stack_name \
            --template-body file://cloudformation/main-stack.yaml \
            --parameters file://$param_file \
            --capabilities CAPABILITY_IAM \
            --region $REGION
        
        log_info "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete \
            --stack-name $stack_name \
            --region $REGION
    else
        log_info "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name $stack_name \
            --template-body file://cloudformation/main-stack.yaml \
            --parameters file://$param_file \
            --capabilities CAPABILITY_IAM \
            --region $REGION
        
        log_info "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete \
            --stack-name $stack_name \
            --region $REGION
    fi
    
    log_success "Infrastructure stack deployed successfully"
    
    # Get stack outputs
    local stack_outputs=$(aws cloudformation describe-stacks \
        --stack-name $stack_name \
        --region $REGION \
        --query 'Stacks[0].Outputs' \
        --output json)
    
    echo "$stack_outputs" > temp/stack-outputs.json
    
    return 0
}

deploy_monitoring() {
    log_info "Deploying monitoring stack..."
    
    # Get infrastructure stack outputs
    if [ ! -f "temp/stack-outputs.json" ]; then
        log_error "Infrastructure stack outputs not found. Deploy infrastructure first."
        exit 1
    fi
    
    # Extract values from stack outputs
    local web_server1_id=$(jq -r '.[] | select(.OutputKey=="WebServer1Id") | .OutputValue' temp/stack-outputs.json)
    local web_server2_id=$(jq -r '.[] | select(.OutputKey=="WebServer2Id") | .OutputValue' temp/stack-outputs.json)
    # local load_balancer_arn=$(jq -r '.[] | select(.OutputKey=="LoadBalancerArn") | .OutputValue' temp/stack-outputs.json)
    local database_endpoint=$(jq -r '.[] | select(.OutputKey=="DatabaseEndpoint") | .OutputValue' temp/stack-outputs.json)
    local target_group_arn=$(jq -r '.[] | select(.OutputKey=="TargetGroupArn") | .OutputValue' temp/stack-outputs.json)
    
    # Create monitoring parameters
    cat > "temp/monitoring-params.json" << EOF
[
  {
    "ParameterKey": "Environment",
    "ParameterValue": "$ENVIRONMENT"
  },
  {
    "ParameterKey": "WebServer1Id",
    "ParameterValue": "$web_server1_id"
  },
  {
    "ParameterKey": "WebServer2Id",
    "ParameterValue": "$web_server2_id"
  },
  {
    "ParameterKey": "LoadBalancerArn",
    "ParameterValue": "$load_balancer_arn"
  },
  {
    "ParameterKey": "DatabaseEndpoint",
    "ParameterValue": "$database_endpoint"
  },
  {
    "ParameterKey": "TargetGroupArn",
    "ParameterValue": "$target_group_arn"
  }
]
EOF
    
    # Deploy monitoring stack
    local monitoring_stack_name="aws-monitoring-${ENVIRONMENT}-monitoring"
    
    if aws cloudformation describe-stacks --stack-name $monitoring_stack_name --region $REGION &> /dev/null; then
        log_info "Updating monitoring stack..."
        aws cloudformation update-stack \
            --stack-name $monitoring_stack_name \
            --template-body file://cloudformation/monitoring-stack.yaml \
            --parameters file://temp/monitoring-params.json \
            --capabilities CAPABILITY_IAM \
            --region $REGION
        
        aws cloudformation wait stack-update-complete \
            --stack-name $monitoring_stack_name \
            --region $REGION
    else
        log_info "Creating monitoring stack..."
        aws cloudformation create-stack \
            --stack-name $monitoring_stack_name \
            --template-body file://cloudformation/monitoring-stack.yaml \
            --parameters file://temp/monitoring-params.json \
            --capabilities CAPABILITY_IAM \
            --region $REGION
        
        aws cloudformation wait stack-create-complete \
            --stack-name $monitoring_stack_name \
            --region $REGION
    fi
    
    log_success "Monitoring stack deployed successfully"
}

show_deployment_summary() {
    log_info "Deployment Summary"
    echo "===================="
    echo "Environment: $ENVIRONMENT"
    echo "Region: $REGION"
    echo ""
    
    # Get dashboard URL
    local monitoring_stack_name="aws-monitoring-${ENVIRONMENT}-monitoring"
    local dashboard_url=$(aws cloudformation describe-stacks \
        --stack-name $monitoring_stack_name \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue' \
        --output text 2>/dev/null || echo "Not available")
    
    echo "Dashboard URL: $dashboard_url"
    echo ""
    
    # Show stack resources
    echo "Deployed Stacks:"
    aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --region $REGION \
        --query "StackSummaries[?starts_with(StackName, 'aws-monitoring-${ENVIRONMENT}')].{Name:StackName,Status:StackStatus}" \
        --output table
    
    log_success "Deployment completed successfully!"
}

cleanup() {
    # Clean up temporary files
    if [ -d "temp" ]; then
        rm -rf temp
    fi
}

# Main execution
main() {
    log_info "Starting AWS Infrastructure Monitoring deployment..."
    log_info "Environment: $ENVIRONMENT, Region: $REGION"
    
    # Create temp directory
    mkdir -p temp
    
    # Trap to ensure cleanup happens
    trap cleanup EXIT
    
    # Run deployment steps
    check_prerequisites
    validate_templates
    
    if [ "$VALIDATE_ONLY" = true ]; then
        log_success "Validation completed successfully"
        exit 0
    fi
    
    run_tests
    
    # Create S3 bucket for deployment artifacts
    S3_BUCKET=$(create_s3_bucket)
    
    # Package Lambda functions
    package_lambda_functions $S3_BUCKET
    
    # Deploy infrastructure
    deploy_infrastructure $S3_BUCKET
    
    # Deploy monitoring components
    deploy_monitoring
    
    # Show summary
    show_deployment_summary
    
    # Cleanup S3 bucket (optional)
    read -p "Do you want to delete the deployment S3 bucket? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting S3 bucket: $S3_BUCKET"
        aws s3 rb s3://$S3_BUCKET --force --region $REGION
        log_success "S3 bucket deleted"
    else
        log_info "S3 bucket preserved: $S3_BUCKET"
    fi
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi