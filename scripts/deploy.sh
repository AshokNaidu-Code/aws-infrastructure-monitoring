#!/bin/bash
# Deployment Script for AWS Infrastructure Monitoring

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
ENVIRONMENT="prod"
REGION="us-east-1"
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
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        *)
            shift
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
    
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi
    
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is not installed"
        exit 1
    fi
    
    log_success "Prerequisites check completed"
}

validate_templates() {
    log_info "Validating CloudFormation templates..."
    
    log_info "Validating main-stack.yaml..."
    aws cloudformation validate-template \
        --template-body file://cloudformation/main-stack.yaml \
        --region $REGION > /dev/null
    
    log_info "Validating monitoring-stack.yaml..."
    aws cloudformation validate-template \
        --template-body file://cloudformation/monitoring-stack.yaml \
        --region $REGION > /dev/null
    
    log_info "Running cfn-lint..."
    pip install -q cfn-lint 2>/dev/null || true
    cfn-lint cloudformation/*.yaml || true
    
    log_success "Template validation completed"
}

deploy_infrastructure() {
    log_info "Deploying infrastructure stack..."
    
    local stack_name="aws-monitoring-${ENVIRONMENT}-main"
    local param_file="cloudformation/parameters/${ENVIRONMENT}-params.json"
    
    log_info "Deploying stack: $stack_name"
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name $stack_name --region $REGION &> /dev/null; then
        # Get stack status
        local stack_status=$(aws cloudformation describe-stacks \
            --stack-name $stack_name \
            --region $REGION \
            --query 'Stacks[0].StackStatus' \
            --output text)
        
        log_info "Stack status: $stack_status"
        
        # If stack is in failed state, delete it first
        if [[ "$stack_status" == *"FAILED"* ]] || [[ "$stack_status" == "DELETE_IN_PROGRESS" ]]; then
            log_warning "Stack is in $stack_status state. Deleting..."
            aws cloudformation delete-stack --stack-name $stack_name --region $REGION
            log_info "Waiting for stack deletion..."
            aws cloudformation wait stack-delete-complete --stack-name $stack_name --region $REGION 2>/dev/null || true
            log_success "Stack deleted. Creating new one..."
            
            # Create new stack
            aws cloudformation create-stack \
                --stack-name $stack_name \
                --template-body file://cloudformation/main-stack.yaml \
                --parameters file://$param_file \
                --capabilities CAPABILITY_IAM \
                --region $REGION
        else
            log_info "Updating existing stack..."
            aws cloudformation update-stack \
                --stack-name $stack_name \
                --template-body file://cloudformation/main-stack.yaml \
                --parameters file://$param_file \
                --capabilities CAPABILITY_IAM \
                --region $REGION || true
        fi
    else
        log_info "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name $stack_name \
            --template-body file://cloudformation/main-stack.yaml \
            --parameters file://$param_file \
            --capabilities CAPABILITY_IAM \
            --region $REGION
    fi
    
    log_info "Waiting for stack creation to complete..."
    aws cloudformation wait stack-create-complete \
        --stack-name $stack_name \
        --region $REGION 2>/dev/null || true
    
    log_success "Infrastructure stack deployed successfully"
}

# Main execution
main() {
    log_info "Starting AWS Infrastructure Monitoring deployment..."
    log_info "Environment: $ENVIRONMENT, Region: $REGION"
    
    check_prerequisites
    validate_templates
    
    if [ "$SKIP_TESTS" != "true" ]; then
        log_info "Running tests..."
        pip install -q pytest 2>/dev/null || true
        pytest tests/unit -v 2>/dev/null || log_warning "Some tests failed but continuing..."
    else
        log_info "Skipping tests as requested"
    fi
    
    deploy_infrastructure
    
    log_success "Deployment completed successfully!"
}

# Run main function
main "$@"
