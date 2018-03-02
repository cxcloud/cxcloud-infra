#!/usr/bin/env bash

set -euo pipefail

function help(){
    echo "";
    echo "Usage: ecr-update-service.sh cluster_name service_name image_tag";
    exit 1;
}

if [[ $# -ne 3 ]]; then
    help
fi

CLUSTER_NAME=$1
SERVICE_NAME=$2
NEW_IMAGE_TAG=$3

CURRENT_TASK_DEF_ARN=$(aws ecs describe-services --cluster $1 --service $2 --query "services[*].taskDefinition" --output text)
CURRENT_TASK_DEF=$(aws ecs describe-task-definition --task-definition $CURRENT_TASK_DEF_ARN)

CURRENT_IMAGE_NAME_WO_TAG=$(echo $CURRENT_TASK_DEF | jq -r '.taskDefinition.containerDefinitions[0].image | split(":")[0:-1] | join("")')

NEW_IMAGE_URL=$CURRENT_IMAGE_NAME_WO_TAG:$NEW_IMAGE_TAG

NEW_TASK_DEF=$(echo $CURRENT_TASK_DEF | jq ".taskDefinition | .containerDefinitions[0].image |= \"$NEW_IMAGE_URL\" | del(.taskDefinitionArn,.status,.revision,.requiresAttributes,.compatibilities)")

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" | jq -r '.taskDefinition.taskDefinitionArn')
echo $NEW_TASK_DEF_ARN

aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN

