import boto3

client = boto3.client('cloudwatch')
with open('dashboards/main-dashboard.json') as f:
    dashboard_body = f.read()
client.put_dashboard(
    DashboardName='MainDashboard',
    DashboardBody=dashboard_body
)
