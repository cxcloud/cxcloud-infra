provider "aws" {
  region = "eu-west-1"
  assume_role {
    role_arn = "${lookup(var.workspace_iam_roles, terraform.workspace)}"
  }
}

locals {
  env_to_node_env_map = {
    "dev"  = "development"
    "test" = "staging"
    "prod" = "production"
  }
}

module "ecr_repository" {
  source          = "../modules/ecr_repository"
  dev_account_id  = "${var.aws_dev_account_id}"
  prod_account_id = "${var.aws_prod_account_id}"
  name            = "${var.container_name}"
}

module "container_definition" {
  source         = "github.com/tieto-cem/terraform-aws-ecs-task-definition//modules/container-definition?ref=v0.1.3"
  name           = "${var.container_name}"
  image          = "${module.ecr_repository.url}:latest"
  mem_soft_limit = "${var.container_mem_soft_limit}"
  port_mappings  = [{
    containerPort = "${var.container_port}"
  }]
  environment    = [{
    name = "NODE_ENV", value = "${lookup(local.env_to_node_env_map, terraform.workspace)}"
  }, {
    name = "CT_EVENT_QUEUE", value = "${aws_sqs_queue.ct_event_queue.name}"
  }, {
    name = "ACTION_QUEUE", value = "${aws_sqs_queue.action_queue.name}"
  }]
}

module "task_definition" {
  source                = "github.com/tieto-cem/terraform-aws-ecs-task-definition?ref=v0.1.3"
  name                  = "${var.application_name}-${terraform.workspace}-${var.container_name}"
  container_definitions = ["${module.container_definition.json}"]
}

resource "aws_iam_role_policy" "task_policy" {
  name   = "${var.application_name}-${terraform.workspace}-${var.container_name}-task-policy"
  role   = "${module.task_definition.role_id}"
  policy = <<EOF
{
  "Version":"2012-10-17",
  "Statement": [
    {
        "Effect": "Allow",
        "Action": [
            "sqs:DeleteMessage",
            "sqs:ReceiveMessage",
            "sqs:GetQueueUrl",
            "sqs:ChangeMessageVisibility"
        ],
        "Resource": "${aws_sqs_queue.ct_event_queue.arn}"
    },
    {
        "Effect": "Allow",
        "Action": [
            "sqs:DeleteMessage",
            "sqs:ReceiveMessage",
            "sqs:SendMessage",
            "sqs:GetQueueUrl",
            "sqs:ChangeMessageVisibility"
        ],
        "Resource": "${aws_sqs_queue.action_queue.arn}"
    },
    {
        "Effect": "Allow",
        "Action": [
            "sqs:GetQueueUrl",
            "sqs:ListQueues"
        ],
        "Resource": "*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "ses:SendEmail",
            "ses:SendRawEmail"
        ],
        "Resource": "*"
    }
  ]
}
EOF
}

module "service" {
  source                   = "github.com/tieto-cem/terraform-aws-ecs-service?ref=v0.1.1"
  name                     = "${var.application_name}-${terraform.workspace}-${var.container_name}"
  cluster_name             = "${data.terraform_remote_state.shared.cluster_name}"
  task_definition_family   = "${module.task_definition.family}"
  task_definition_revision = "${module.task_definition.revision}"
  desired_count            = "${lookup(var.task_desired_count, terraform.workspace)}"
  use_load_balancer        = false
}

data "template_file" "buildspec" {
  count    = "${terraform.workspace == "dev" ? 1 : 0}"
  template = "${file("${path.module}/buildspec.yml")}"

  vars {
    REPOSITORY_URI = "${module.ecr_repository.url}"
    CONTAINER_NAME = "${var.container_name}"
  }
}

module "pipeline" {
  source                = "../modules/ecs_pipeline"
  github_user           = "${var.github_user}"
  github_repository     = "${var.github_repository}"
  gitcrypt_pass         = "${var.gitcrypt_pass}"
  build_spec            = "${terraform.workspace == "dev" ? join("", data.template_file.buildspec.*.rendered) : ""}"
  pipeline_name         = "${var.application_name}-${var.container_name}"
  ecs_dev_cluster_name  = "${data.terraform_remote_state.shared.cluster_name}"
  ecs_dev_service_name  = "${module.service.name}"
  terraform_prod_role   = "${lookup(var.workspace_iam_roles, "prod")}"
  create_pipeline       = "${terraform.workspace == "dev" ? true : false}"
}