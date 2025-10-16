import json
import boto3
import numpy as np

def lambda_handler(event, context):
    metric_values = event.get("metric_values", [])
    if len(metric_values) > 2:
        mean = np.mean(metric_values)
        std = np.std(metric_values)
        threshold = mean + 2 * std
        alert = event.get("latest") > threshold
        return { "alert": alert, "threshold": threshold }
    return { "alert": False }
