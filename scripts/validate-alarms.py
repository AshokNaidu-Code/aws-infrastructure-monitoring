import boto3

client = boto3.client('cloudwatch')
alarms = client.describe_alarms()
print("CloudWatch Alarms in account:")
for a in alarms['MetricAlarms']:
    print(a['AlarmName'], a['StateValue'])
