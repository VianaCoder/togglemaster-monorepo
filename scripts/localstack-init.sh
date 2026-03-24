#!/bin/bash
# LocalStack initialization script.
# Mounted at /etc/localstack/init/ready.d/ — runs automatically once LocalStack
# reports itself as ready.  Uses the bundled `awslocal` CLI (a thin wrapper
# around `aws` that points to the local endpoint).

set -e

echo ">>> [localstack-init] Creating SQS queue: toggle-master-events"
awslocal sqs create-queue \
  --queue-name toggle-master-events \
  --attributes VisibilityTimeout=30

echo ">>> [localstack-init] Creating DynamoDB table: ToggleMasterAnalytics"
awslocal dynamodb create-table \
  --table-name ToggleMasterAnalytics \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

echo ">>> [localstack-init] All AWS resources created successfully."
