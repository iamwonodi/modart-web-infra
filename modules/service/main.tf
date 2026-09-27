# ------------------------------------------------------------------------------
# SERVICE
#
# The cloud resources one service needs, and the document its application
# repository reads to deploy onto them. Where the platform hosts services on a
# shared fleet the service attaches to it; where hosting is dedicated the service
# creates its own hosts (see modules/service-hosting):
#
#   ECR repository      where its images live
#   secret              generated application secrets, and (with a database) its
#                       database name, user and password
#   target group        the load balancer's view of the service
#   ALB rule            <service>.<domain> -> the target group, tagged Service=<service>
#   ingress rule        the tier's load balancer may reach the service's port
#   ASG attachment      (shared) the target group joins the tier's auto scaling group
#   hosts               (dedicated) the service's own group, role, bucket and document
#   service config      /<project>/services/<service>/config, read by the app repository
#   agents              (with a database) the team's own logins on its database,
#                       their passwords in the secret; and, where the platform has
#                       a front door, their emails declared for sign-ins
#
# The shared fleet, its load balancer and the database are core's, discovered
# through the platform contract, never created or changed here except for the
# single attachment, rule and ingress rule that connect this service to them.
#
# What does NOT happen here: creating the service's database and user inside the
# engine. This repository publishes the request and the apply workflow triggers
# core's provisioning; the SQL is core's. Nor is a service's own extra SQL run on a
# managed database.
#
# Every resource name follows core's <project>-<environment>-<service>-<resource>
# convention, because the permissions core grants this repository's role are
# scoped to exactly those names. The secret and the target group are the one
# exception, <project>-<service>-<environment>, until terraform-aws-secrets-vault
# and terraform-aws-target-group release a v2 that follows the rule.
# ------------------------------------------------------------------------------

data "aws_ssm_parameter" "platform" {
  name = "/${var.project_name}/platform/config"
}

# Everything that can be worked out from the contract, and the checks that stop
# the plan early. Nothing here creates a resource.
module "model" {
  source = "../service-model"

  project_name      = var.project_name
  environment       = var.environment
  service_name      = var.service_name
  service_type      = var.service_type
  tier              = var.tier
  service_port      = var.service_port
  database_engine   = var.database_engine
  health_check_path = var.health_check_path
  subdomain         = var.subdomain
  agents            = var.agents

  platform_json = data.aws_ssm_parameter.platform.insecure_value
}

resource "terraform_data" "service_invariants" {
  lifecycle {
    precondition {
      condition     = length(var.generated_secret_names) > 0 || var.database_engine != null
      error_message = "The service's secret would be empty. List generated_secret_names, set database_engine, or both."
    }
  }
}

# ------------------------------------------------------------------------------
# Secret
#
# Only letters, digits and "-_." are used: characters such as $ and # are
# corrupted by the env files these values pass through.
# ------------------------------------------------------------------------------

resource "random_password" "generated" {
  for_each = toset(var.generated_secret_names)

  length           = var.secret_length
  special          = true
  override_special = "-_."
}

resource "random_password" "database" {
  count = var.database_engine == null ? 0 : 1

  length           = 32
  special          = true
  override_special = "-_."
}

# One password per agent, in the platform's alphabet. To give an agent a new
# one: terraform apply -replace='module.service.random_password.agent["<name>"]'.
resource "random_password" "agent" {
  for_each = var.agents

  length           = 40
  special          = true
  override_special = "-_."
}

locals {
  secret_values = merge(
    { for name, generated in random_password.generated : name => generated.result },
    var.database_engine == null ? {} : {
      db_name     = module.model.database_identifier
      db_user     = module.model.database_identifier
      db_password = random_password.database[0].result
    },
    # The agents, for core's provisioning: a JSON object in one entry (the
    # secret's values are strings). Only the service team's administrators and
    # core's provisioning read it; the application's env file never includes it,
    # since the deploy copies only the entries the env file names.
    length(var.agents) == 0 ? {} : {
      agents = jsonencode({
        for name, agent in var.agents : name => {
          password = random_password.agent[name].result
          access   = agent.access
        }
      })
    },
  )

  # Core's policy lets this repository tag a resource only when Service names this
  # service, and its ALB-rule permissions are conditioned on the same tag.
  tags = {
    Service = var.service_name
  }
}

module "vault" {
  source = "git::https://github.com/iamwonodi/terraform-aws-secrets-vault.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = var.service_name

  secret_kv_pairs = local.secret_values

  depends_on = [terraform_data.service_invariants]
}

# ------------------------------------------------------------------------------
# Image repository
# ------------------------------------------------------------------------------

module "repository" {
  source = "git::https://github.com/iamwonodi/terraform-aws-ecr.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = var.service_name
  service_type = var.service_type

  image_tag_mutability    = var.image_tag_mutability
  scan_on_push            = true
  enable_lifecycle_policy = true
  lifecycle_image_count   = var.lifecycle_image_count
}

# ------------------------------------------------------------------------------
# Routing
# ------------------------------------------------------------------------------

module "target_group" {
  source = "git::https://github.com/iamwonodi/terraform-aws-target-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = var.service_name

  vpc_id            = module.model.platform.vpc_id
  port              = var.service_port
  health_check_path = var.health_check_path
}

# The tier's load balancer may reach the service's port on the shared hosts. With
# dedicated hosting the service owns its hosts' group, so the rule lives there.
module "ingress_rule" {
  count = module.model.is_dedicated ? 0 : 1

  source = "git::https://github.com/iamwonodi/terraform-aws-sg-ingress-rule.git?ref=v1.2.2"

  description = "Allow the ${var.tier} load balancer to reach ${var.service_name} on port ${var.service_port}"

  security_group_id            = module.model.tier.security_group_id
  referenced_security_group_id = module.model.tier.alb_security_group_id

  ip_protocol = "tcp"
  from_port   = var.service_port
  to_port     = var.service_port

  tags = merge(local.tags, { Name = "${module.model.target_group_name}-ingress" })
}

# Joins the service's target group to the tier's shared auto scaling group. The
# group itself belongs to core, which ignores target groups attached from outside.
resource "aws_autoscaling_attachment" "this" {
  count = module.model.is_dedicated ? 0 : 1

  autoscaling_group_name = module.model.tier.asg_name
  lb_target_group_arn    = module.target_group.arn
}

module "alb_rule" {
  source = "git::https://github.com/iamwonodi/terraform-aws-alb-rule.git?ref=v1.0.0"

  listener_arn = module.model.tier.listener_arn

  actions = [
    {
      type             = "forward"
      target_group_arn = module.target_group.arn
    }
  ]

  conditions = [
    {
      host_header = {
        values = [module.model.domain]
      }
    }
  ]

  # Service must equal this service's name: core's policy lets this role create
  # and change only rules that carry it.
  tags = merge(local.tags, { Purpose = "${var.service_name} traffic" })
}

# ------------------------------------------------------------------------------
# The service's database
#
# The credentials were generated into the secret above. Core's provisioning script
# reads them on the database host and creates the database, the user and its
# grants; this repository only publishes the request that names where they are.
# The apply workflow then sends core's document and waits for it.
#
# Publishing is declarative, so the request is versioned with everything else, and
# a service with no database publishes nothing.
# ------------------------------------------------------------------------------

resource "aws_s3_object" "provisioning_request" {
  count = module.model.provision_document == null ? 0 : 1

  bucket       = module.model.platform.buckets.deploy
  key          = "${module.model.provisioning_prefix}/config.json"
  content      = module.config.provisioning_request_json
  content_type = "application/json"

  # The content is not a secret, but it names one. Server-side encryption is the
  # bucket's default; this only keeps the object out of any request log body.
  server_side_encryption = "AES256"

  tags = local.tags
}

# The service's own extra SQL, if it has any. It runs as the service's user on
# the service's own database.
resource "aws_s3_object" "provisioning_extra_sql" {
  count = module.model.provision_document != null && var.database_extra_sql_path != null ? 1 : 0

  bucket = module.model.platform.buckets.deploy
  key    = "${module.model.provisioning_prefix}/extra.sql"
  source = var.database_extra_sql_path
  etag   = filemd5(coalesce(var.database_extra_sql_path, "/dev/null"))

  tags = local.tags
}

# ------------------------------------------------------------------------------
# The front door
#
# Where the platform has one (development, staging), the service declares its
# agents' emails in its own file; core's function turns every declaration into
# sign-ins to the team tools. Written even when empty, so removing the last agent
# removes their sign-in. Destroying the service deletes it, and so theirs.
# ------------------------------------------------------------------------------

resource "aws_s3_object" "front_door_declaration" {
  count = module.model.front_door_declaration_key == null ? 0 : 1

  bucket       = module.model.platform.buckets.deploy
  key          = module.model.front_door_declaration_key
  content      = jsonencode({ emails = sort([for agent in values(var.agents) : lower(agent.email)]) })
  content_type = "application/json"

  tags = local.tags
}

resource "terraform_data" "database_provisioning_supported" {
  count = var.database_engine == null ? 0 : 1

  lifecycle {
    # Extra SQL runs as the service's own user on the EC2 host. Core's function on
    # a managed database runs only its standard statements, so the file would be
    # silently ignored there: refuse instead.
    precondition {
      condition     = var.database_extra_sql_path == null || module.model.provision_document != null
      error_message = "database_extra_sql_path is set, but this environment's database is managed and core's provisioning function runs no service-supplied SQL. Remove it here, or apply it from a migration in the application."
    }

    precondition {
      condition     = module.model.provision_document != null || module.model.provision_function != null
      error_message = "This service uses a database, but the platform publishes neither a provisioning document (EC2 database host) nor a provisioning function (managed database) for this environment, so the service's database and user would never be created."
    }
  }
}

# ------------------------------------------------------------------------------
# The service's own hosts (staging and production)
#
# Where the platform hosts services dedicated, the service creates its own hosts
# rather than attaching to the tier's fleet. Core still owns the image they boot
# and the scripts they run.
# ------------------------------------------------------------------------------

module "hosting" {
  source = "../service-hosting"
  count  = module.model.is_dedicated ? 1 : 0

  project_name = var.project_name
  environment  = var.environment
  service_name = var.service_name
  service_port = var.service_port

  permissions_boundary_arn = module.model.service_boundary_arn

  ami_parameter              = module.model.ami_parameter
  scripts_manifest_parameter = module.model.scripts_manifest_parameter
  platform_deploy_bucket     = module.model.shared_deploy_bucket
  platform_prefix            = module.model.platform_prefix

  config_bucket = module.model.config_bucket

  vpc_id = module.model.platform.vpc_id
  # Where the tier's hosts go, as the platform publishes it: nothing hard-coded.
  subnet_ids             = module.model.tier.subnet_ids
  alb_security_group_id  = module.model.tier.alb_security_group_id
  tier_security_group_id = module.model.tier.security_group_id

  ecr_registry_url = module.model.platform.ecr_registry_url
  aws_region       = module.model.platform.region

  target_group_arns = [module.target_group.arn]

  instance_types                           = var.instance_types
  min_size                                 = var.min_size
  desired_capacity                         = var.desired_capacity
  max_size                                 = var.max_size
  on_demand_base_capacity                  = var.on_demand_base_capacity
  on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base_capacity
  root_volume_size                         = var.root_volume_size

  tags = local.tags
}

# ------------------------------------------------------------------------------
# The document the application repository reads
# ------------------------------------------------------------------------------

module "config" {
  source = "../service-model"

  project_name      = var.project_name
  environment       = var.environment
  service_name      = var.service_name
  service_type      = var.service_type
  tier              = var.tier
  service_port      = var.service_port
  database_engine   = var.database_engine
  health_check_path = var.health_check_path
  subdomain         = var.subdomain

  platform_json = data.aws_ssm_parameter.platform.insecure_value

  secret_arn          = module.vault.secret_arn
  secret_name         = module.vault.secret_name
  target_group_arn    = module.target_group.arn
  ecr_repository_url  = module.repository.repository_url
  ecr_repository_name = module.repository.repository_name
}

resource "aws_ssm_parameter" "service_config" {
  name        = module.config.parameter_name
  description = "What the ${var.service_name} application repository needs to deploy the service."
  type        = "String"
  value       = module.config.config_json

  tags = local.tags

  # Written last: the application repository must never read a config that
  # points at resources not yet attached.
  depends_on = [aws_autoscaling_attachment.this, module.alb_rule, module.ingress_rule, module.hosting]
}
