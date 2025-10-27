#!/usr/bin/env python3
import json
import boto3
import sys

def create_dashboards(environment):
    """Create CloudWatch dashboards from JSON configuration files"""
    
    client = boto3.client('cloudwatch')
    dashboards = [
        'dashboards/main-dashboard.json',
        'dashboards/ec2-dashboard.json',
        'dashboards/rds-dashboard.json'
    ]
    
    for dashboard_file in dashboards:
        try:
            # Read the dashboard configuration
            with open(dashboard_file, 'r') as f:
                dashboard_config = json.load(f)  # Parse as JSON object, not string
            
            # Extract dashboard name
            dashboard_name = f"{environment}-{dashboard_file.split('/')[-1].replace('-dashboard.json', '')}"
            
            print(f"Creating dashboard: {dashboard_name}")
            
            # Create the dashboard
            response = client.put_dashboard(
                DashboardName=dashboard_name,
                DashboardBody=json.dumps(dashboard_config)  # Convert back to string for API
            )
            
            print(f"✓ Dashboard created: {dashboard_name}")
            
        except FileNotFoundError:
            print(f"⚠ Dashboard file not found: {dashboard_file} (skipping)")
        except json.JSONDecodeError as e:
            print(f"✗ Invalid JSON in {dashboard_file}: {e}")
            sys.exit(1)
        except Exception as e:
            print(f"✗ Error creating dashboard from {dashboard_file}: {e}")
            sys.exit(1)

if __name__ == '__main__':
    environment = sys.argv[1] if len(sys.argv) > 1 else 'prod'
    print(f"Creating dashboards for environment: {environment}")
    create_dashboards(environment)
    print("✓ All dashboards created successfully!")
