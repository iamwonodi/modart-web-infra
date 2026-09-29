# ------------------------------------------------------------------------------
# DEDICATED HOSTS
#
# In staging and production a service runs on its OWN hosts rather than sharing
# the tier's fleet. This module builds them: the configuration bucket its
# application repository publishes into, the instance role they run as, their
# security group, launch template and auto scaling group, and the SSM document
# that redeploys them.
#
#   core                              this module
#   ────                              ───────────
#   golden AMI  ──> SSM parameter ──> launch template ──> auto scaling group
#   deploy scripts in _platform/  ──> installed at boot ──┘
#                                                          |
#   the application repository ──> config bucket ──────────┘
#                                  services/<service>/
#
# WHAT CORE STILL OWNS: the image these hosts boot and the scripts they run. A
# fix to either is one rebuild or one upload, rather than one change in every
# service repository.
#
# THE BOUNDARY IS NOT OPTIONAL. Core's policy lets this repository create an IAM
# role only under /services/<service>/, only carrying the platform's permissions
# boundary, and only tagged with this service's name. A role created any other
# way is refused by IAM, not by this module.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Configuration bucket
# ------------------------------------------------------------------------------

module "config_bucket" {
  source = "git::https://github.com/iamwonodi/terraform-aws-s3.git?ref=v1.0.0"

  bucket_name = var.config_bucket

  versioning_enabled = true
  object_ownership   = "BucketOwnerEnforced"

  block_public_access = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  encryption = {
    type = "SSE-S3"
  }

  tags = local.tags
}

# ------------------------------------------------------------------------------
# The role the hosts run as
# ------------------------------------------------------------------------------

resource "aws_iam_role" "instance" {
  name        = "${local.name}-instance"
  path        = local.iam_path
  description = "Hosts running ${var.service_name} in ${var.environment}."

  assume_role_policy   = data.aws_iam_policy_document.instance_trust.json
  permissions_boundary = var.permissions_boundary_arn

  tags = local.tags
}

resource "aws_iam_role_policy" "instance" {
  name   = "host"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  path = local.iam_path
  role = aws_iam_role.instance.name

  tags = local.tags
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

resource "aws_security_group" "instance" {
  name        = "${local.name}-hosts"
  description = "Hosts running ${var.service_name}."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-hosts" })

  lifecycle {
    create_before_destroy = true
  }
}

# Only the tier's load balancer, and only on the service's port.
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.instance.id
  referenced_security_group_id = var.alb_security_group_id

  description = "Allow the ${var.environment} load balancer to reach ${var.service_name}."

  ip_protocol = "tcp"
  from_port   = var.service_port
  to_port     = var.service_port

  tags = local.tags
}

# The hosts pull images, read S3 and Secrets Manager, and talk to SSM. Some of
# that is reached through interface endpoints and some through NAT, and neither
# is expressible as a narrower egress rule than this.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  description = "Outbound: image pulls, S3, Secrets Manager and SSM."

  tags = local.tags
}

# ------------------------------------------------------------------------------
# The hosts
# ------------------------------------------------------------------------------

module "launch_template" {
  source = "git::https://github.com/iamwonodi/terraform-aws-launch-template.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = var.service_name

  # insecure_value is the parameter's non-sensitive form: an AMI ID is not secret.
  ami_id = data.aws_ssm_parameter.ami.insecure_value

  instance_type             = var.instance_types[0]
  iam_instance_profile_name = aws_iam_instance_profile.instance.name

  # The service's own group admits its load balancer. The tier's group is what the
  # databases and the Secrets Manager endpoint admit; without it the hosts could
  # reach neither their database nor their secret.
  security_group_ids = [aws_security_group.instance.id, var.tier_security_group_id]

  user_data = base64encode(local.user_data)

  # The root volume holds the container images as well as the operating system.
  # /dev/sda1 is the root device name on Ubuntu AMIs.
  block_device_mappings = [
    {
      device_name           = "/dev/sda1"
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  ]

  # IMDSv2 only: a token is required, so a request forged through the application
  # cannot read the instance's credentials.
  metadata_http_tokens = "required"
}

module "autoscaling_group" {
  source = "git::https://github.com/iamwonodi/terraform-aws-autoscaling.git?ref=v3.0.1"

  project_name = var.project_name
  environment  = var.environment
  service_name = var.service_name

  launch_template_id      = module.launch_template.id
  launch_template_version = module.launch_template.latest_version

  subnet_ids = var.subnet_ids

  min_size         = var.min_size
  desired_capacity = var.desired_capacity
  max_size         = var.max_size

  mixed_instances_enabled = true
  instance_types          = var.instance_types

  on_demand_base_capacity                  = var.on_demand_base_capacity
  on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base_capacity
  spot_allocation_strategy                 = "price-capacity-optimized"
  capacity_rebalance                       = true

  # This group runs ONE service and this configuration owns its target group, so
  # the load balancer's view of health is the one that matters and the module may
  # attach it. A shared fleet is the opposite on both counts.
  manage_traffic_sources = true
  target_group_arns      = var.target_group_arns

  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period
}

# ------------------------------------------------------------------------------
# Redeploying
# ------------------------------------------------------------------------------
# The only thing this document can do is run the deploy script, so the
# application repository's permission to send it is not permission to run
# arbitrary commands on the hosts.
# ------------------------------------------------------------------------------

resource "aws_ssm_document" "update" {
  name            = local.update_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Runs the deploy script on a ${var.service_name} host."

    parameters = {
      jitterSeconds = {
        type           = "String"
        description    = "Maximum random delay in seconds before deploying, so hosts do not all restart a container at once. Use 0 for an immediate deploy."
        default        = "0"
        allowedPattern = "^[0-9]{1,3}$"
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "runUpdate"
        inputs = {
          timeoutSeconds = "1800"
          runCommand     = ["JITTER_SECONDS={{ jitterSeconds }} ${local.application_root}/update.sh"]
        }
      }
    ]
  })

  tags = local.tags
}
