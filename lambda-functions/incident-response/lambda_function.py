# Lambda Function: Main Incident Response Handler
# File: lambda-functions/incident-response/lambda_function.py

import json
import boto3
import logging
from datetime import datetime
import os

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
ec2 = boto3.client('ec2')
elbv2 = boto3.client('elbv2')
rds = boto3.client('rds')
sns = boto3.client('sns')
cloudwatch = boto3.client('cloudwatch')

def lambda_handler(event, context):
    """
    Main Lambda handler for automated incident response
    Processes CloudWatch alarms and executes appropriate responses
    """
    try:
        logger.info(f"Received event: {json.dumps(event)}")
        
        # Extract SNS message from the event
        sns_message = json.loads(event['Records'][0]['Sns']['Message'])
        
        # Extract alarm details
        alarm_name = sns_message['AlarmName']
        alarm_state = sns_message['NewStateValue']
        alarm_reason = sns_message['NewStateReason']
        region = sns_message['Region']
        
        logger.info(f"Processing alarm: {alarm_name}, State: {alarm_state}")
        
        # Only process ALARM state
        if alarm_state != 'ALARM':
            logger.info(f"Alarm state is {alarm_state}, no action needed")
            return {
                'statusCode': 200,
                'body': json.dumps(f'Alarm {alarm_name} is in {alarm_state} state - no action needed')
            }
        
        # Determine incident severity and category
        severity = determine_severity(alarm_name, sns_message)
        category = determine_category(alarm_name)
        
        logger.info(f"Incident severity: {severity}, Category: {category}")
        
        # Execute automated response
        response_result = execute_incident_response(
            alarm_name, alarm_state, severity, category, sns_message
        )
        
        # Log incident for audit trail
        log_incident(alarm_name, alarm_state, severity, category, response_result, context)
        
        # Send notification about automated response
        send_response_notification(alarm_name, severity, response_result)
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Incident response executed successfully',
                'alarm_name': alarm_name,
                'severity': severity,
                'actions_taken': response_result
            })
        }
        
    except Exception as e:
        logger.error(f"Error processing incident: {str(e)}", exc_info=True)
        
        # Send error notification
        alarm_name = alarm_name if 'alarm_name' in locals() else 'Unknown'
        error_message = f"Failed to process incident response for alarm: {alarm_name}. Error: {str(e)}"
        send_error_notification(error_message)
        
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error processing incident: {str(e)}')
        }

def determine_severity(alarm_name, message):
    """Determine incident severity based on alarm characteristics"""
    critical_indicators = [
        'StatusCheck', 'UnhealthyTargets', 'DatabaseConnections', 'SystemHealth'
    ]
    
    high_indicators = [
        'HighCPU', 'High5XX', 'LowFreeStorage'
    ]
    
    if any(indicator in alarm_name for indicator in critical_indicators):
        return 'CRITICAL'
    elif any(indicator in alarm_name for indicator in high_indicators):
        return 'HIGH'
    elif 'HighResponseTime' in alarm_name or 'HighReadLatency' in alarm_name:
        return 'MEDIUM'
    else:
        return 'LOW'

def determine_category(alarm_name):
    """Determine the category of the alarm"""
    if 'WebServer' in alarm_name or 'EC2' in alarm_name:
        return 'EC2'
    elif 'RDS' in alarm_name:
        return 'RDS'
    elif 'ALB' in alarm_name:
        return 'ALB'
    elif 'SystemHealth' in alarm_name:
        return 'SYSTEM'
    else:
        return 'UNKNOWN'

def execute_incident_response(alarm_name, alarm_state, severity, category, message):
    """Execute appropriate response actions based on incident details"""
    actions_taken = []
    
    try:
        if category == 'EC2':
            actions_taken.extend(handle_ec2_incident(alarm_name, severity, message))
        elif category == 'RDS':
            actions_taken.extend(handle_rds_incident(alarm_name, severity, message))
        # elif category == 'ALB':
        #     actions_taken.extend(handle_alb_incident(alarm_name, severity, message))
        elif category == 'SYSTEM':
            actions_taken.extend(handle_system_incident(alarm_name, severity, message))
        
        # Common actions for critical incidents
        if severity == 'CRITICAL':
            actions_taken.extend(handle_critical_incident(alarm_name, message))
            
    except Exception as e:
        logger.error(f"Error executing incident response: {str(e)}")
        actions_taken.append(f"ERROR: {str(e)}")
    
    return actions_taken

def handle_ec2_incident(alarm_name, severity, message):
    """Handle EC2-specific incidents"""
    actions = []
    
    instance_id = extract_instance_id_from_message(message)
    if not instance_id:
        return ["WARNING: Could not identify EC2 instance"]
    
    try:
        if 'StatusCheck' in alarm_name:
            logger.info(f"Attempting to reboot instance {instance_id}")
            ec2.reboot_instances(InstanceIds=[instance_id])
            actions.append(f"Rebooted EC2 instance {instance_id}")
            
        elif 'HighCPU' in alarm_name and severity == 'CRITICAL':
            ec2.create_tags(
                Resources=[instance_id],
                Tags=[
                    {'Key': 'IncidentResponse', 'Value': 'HighCPU'},
                    {'Key': 'ResponseTime', 'Value': datetime.utcnow().isoformat()}
                ]
            )
            actions.append(f"Tagged instance {instance_id} for high CPU investigation")
            
    except Exception as e:
        logger.error(f"Error handling EC2 incident: {str(e)}")
        actions.append(f"ERROR handling EC2 incident: {str(e)}")
    
    return actions

def handle_rds_incident(alarm_name, severity, message):
    """Handle RDS-specific incidents"""
    actions = []
    
    db_identifier = extract_db_identifier_from_message(message)
    if not db_identifier:
        return ["WARNING: Could not identify RDS instance"]
    
    try:
        if 'HighConnections' in alarm_name:
            actions.append(f"High connection count detected on {db_identifier}")
            actions.append("Recommended: Review application connection pooling")
            
        elif 'LowFreeStorage' in alarm_name:
            actions.append(f"Critical: Low storage on {db_identifier}")
            actions.append("Immediate action required: Consider storage scaling")
            
        elif 'HighCPU' in alarm_name:
            actions.append(f"High CPU detected on {db_identifier}")
            actions.append("Enhanced monitoring should be reviewed")
            
    except Exception as e:
        logger.error(f"Error handling RDS incident: {str(e)}")
        actions.append(f"ERROR handling RDS incident: {str(e)}")
    
    return actions

def handle_alb_incident(alarm_name, severity, message):
    """Handle ALB-specific incidents"""
    actions = []
    
    try:
        if 'UnhealthyTargets' in alarm_name:
            target_group_arn = extract_target_group_from_message(message)
            if target_group_arn:
                response = elbv2.describe_target_health(TargetGroupArn=target_group_arn)
                unhealthy_targets = [
                    target for target in response['TargetHealthDescriptions']
                    if target['TargetHealth']['State'] != 'healthy'
                ]
                
                actions.append(f"Found {len(unhealthy_targets)} unhealthy targets")
                
                for target in unhealthy_targets:
                    target_id = target['Target']['Id']
                    health_state = target['TargetHealth']['State']
                    actions.append(f"Target {target_id} is {health_state}")
            
        elif 'High5XX' in alarm_name:
            actions.append("High 5XX error rate detected")
            actions.append("Recommended: Check application logs and target health")
            
        elif 'HighResponseTime' in alarm_name:
            actions.append("High response time detected")
            actions.append("Recommended: Review target performance and scaling")
            
    except Exception as e:
        logger.error(f"Error handling ALB incident: {str(e)}")
        actions.append(f"ERROR handling ALB incident: {str(e)}")
    
    return actions

def handle_system_incident(alarm_name, severity, message):
    """Handle system-wide incidents"""
    actions = []
    
    if 'SystemHealth' in alarm_name:
        actions.append("System-wide health issue detected")
        actions.append("Multiple components may be affected")
        actions.append("Escalating to on-call engineer")
    
    return actions

def handle_critical_incident(alarm_name, message):
    """Handle critical incidents with additional actions"""
    actions = []
    actions.append("Critical incident detected - increasing monitoring frequency")
    return actions

def extract_instance_id_from_message(message):
    """Extract EC2 instance ID from CloudWatch alarm message"""
    try:
        trigger = message.get('Trigger', {})
        dimensions = trigger.get('Dimensions', [])
        
        for dimension in dimensions:
            if dimension.get('name') == 'InstanceId':
                return dimension.get('value')
    except Exception as e:
        logger.error(f"Error extracting instance ID: {str(e)}")
    
    return None

def extract_db_identifier_from_message(message):
    """Extract RDS DB identifier from CloudWatch alarm message"""
    try:
        trigger = message.get('Trigger', {})
        dimensions = trigger.get('Dimensions', [])
        
        for dimension in dimensions:
            if dimension.get('name') == 'DBInstanceIdentifier':
                return dimension.get('value')
    except Exception as e:
        logger.error(f"Error extracting DB identifier: {str(e)}")
    
    return None

def extract_target_group_from_message(message):
    """Extract Target Group ARN from CloudWatch alarm message"""
    try:
        trigger = message.get('Trigger', {})
        dimensions = trigger.get('Dimensions', [])
        
        for dimension in dimensions:
            if dimension.get('name') == 'TargetGroup':
                return dimension.get('value')
    except Exception as e:
        logger.error(f"Error extracting target group: {str(e)}")
    
    return None

def log_incident(alarm_name, alarm_state, severity, category, actions, context):
    """Log incident details for audit trail"""
    incident_log = {
        'timestamp': datetime.utcnow().isoformat(),
        'alarm_name': alarm_name,
        'alarm_state': alarm_state,
        'severity': severity,
        'category': category,
        'actions_taken': actions,
        'lambda_request_id': context.aws_request_id if context else 'unknown'
    }
    
    logger.info(f"INCIDENT_LOG: {json.dumps(incident_log)}")

def send_response_notification(alarm_name, severity, actions):
    """Send notification about automated response actions"""
    try:
        topic_arn = os.environ.get('NOTIFICATION_TOPIC_ARN')
        if not topic_arn:
            logger.warning("No notification topic ARN configured")
            return
        
        message = f"""
Automated Incident Response Executed

Alarm: {alarm_name}
Severity: {severity}
Actions Taken:
{chr(10).join(f"• {action}" for action in actions)}

Timestamp: {datetime.utcnow().isoformat()}
        """
        
        sns.publish(
            TopicArn=topic_arn,
            Subject=f"Automated Response: {alarm_name}",
            Message=message
        )
        
        logger.info("Response notification sent successfully")
        
    except Exception as e:
        logger.error(f"Error sending response notification: {str(e)}")

def send_error_notification(error_message):
    """Send error notification"""
    try:
        topic_arn = os.environ.get('ERROR_TOPIC_ARN')
        if not topic_arn:
            logger.warning("No error notification topic ARN configured")
            return
        
        sns.publish(
            TopicArn=topic_arn,
            Subject="Incident Response Error",
            Message=f"Error in automated incident response: {error_message}"
        )
        
    except Exception as e:
        logger.error(f"Error sending error notification: {str(e)}")