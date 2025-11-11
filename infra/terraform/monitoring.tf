#############################
# Minimal CloudWatch Dashboard
# Focus: SageMaker endpoint latency + invocations
#############################

variable "endpoint_name" {
  description = "SageMaker endpoint name to monitor"
  type        = string
  default     = "condor-xgb"
}

resource "aws_cloudwatch_dashboard" "latency" {
  dashboard_name = "${var.prefix}-latency"

  dashboard_body = jsonencode({
    widgets = [
      {
        "type" : "metric",
        "x" : 0,
        "y" : 0,
        "width" : 18,
        "height" : 8,
        "properties" : {
          "title" : "SageMaker ModelLatency (p50/p95)",
          "view" : "timeSeries",
          "stacked" : false,
          "region" : var.region,
          "stat" : "p95",
          "period" : 60,
          "metrics" : [
            [ "AWS/SageMaker", "ModelLatency", "EndpointName", var.endpoint_name, "VariantName", "AllTraffic", { "stat": "Average" } ],
            [ "AWS/SageMaker", "ModelLatency", "EndpointName", var.endpoint_name, "VariantName", "AllTraffic", { "stat": "p95" } ],
            [ "AWS/SageMaker", "ModelLatency", "EndpointName", var.endpoint_name, "VariantName", "AllTraffic", { "stat": "p50" } ]
          ]
        }
      },
      {
        "type" : "metric",
        "x" : 0,
        "y" : 8,
        "width" : 18,
        "height" : 6,
        "properties" : {
          "title" : "SageMaker Invocations (sum)",
          "view" : "timeSeries",
          "stacked" : false,
          "region" : var.region,
          "stat" : "Sum",
          "period" : 60,
          "metrics" : [
            [ "AWS/SageMaker", "Invocations", "EndpointName", var.endpoint_name, "VariantName", "AllTraffic", { "stat": "Sum" } ]
          ]
        }
      }
    ]
  })
}