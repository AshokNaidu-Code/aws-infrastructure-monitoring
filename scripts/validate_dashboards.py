import json
import sys

dashboard_files = [
    'dashboards/main-dashboard.json',
    'dashboards/ec2-dashboard.json',
    'dashboards/rds-dashboard.json'
]

for file_path in dashboard_files:
    try:
        with open(file_path) as f:
            json.load(f)
        print(f"{file_path} is valid JSON.")
    except Exception as e:
        print(f"{file_path} FAILED JSON validation: {e}")
        sys.exit(1)

print("All dashboard JSON files validated successfully.")
