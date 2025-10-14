import boto3
import json
import requests
from datetime import datetime

def lambda_handler(event, context):
    """
    Proactive health checking across infrastructure
    """
    health_results = {
        'ec2_instances': check_ec2_health(),
        'rds_instances': check_rds_health(),
        'load_balancers': check_alb_health(),
        'timestamp': datetime.utcnow().isoformat()
    }
    
    # Publish custom metrics for health status
    publish_health_metrics(health_results)
    
    return {
        'statusCode': 200,
        'body': json.dumps(health_results)
    }

def check_ec2_health():
    """Check EC2 instance health beyond basic status checks"""
    ec2 = boto3.client('ec2')
    cloudwatch = boto3.client('cloudwatch')
    
    instances = ec2.describe_instances()['Reservations']
    health_data = []
    
    for reservation in instances:
        for instance in reservation['Instances']:
            if instance['State']['Name'] == 'running':
                # Get detailed metrics
                cpu_metrics = get_instance_cpu_metrics(instance['InstanceId'])
                health_data.append({
                    'instance_id': instance['InstanceId'],
                    'cpu_utilization': cpu_metrics,
                    'status': 'healthy' if cpu_metrics < 90 else 'degraded'
                })
    
    return health_data
