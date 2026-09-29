locals {
  platform = jsondecode(var.platform_json)

  hosting_model = try(local.platform.hosting_model, null)
  is_dedicated  = local.hosting_model == "dedicated"
  tier          = try(local.platform.tiers[var.tier], null)

  domain = "${coalesce(var.subdomain, var.service_name)}.${try(local.platform.domain_name, "unknown")}"

  # <project>-<service>-<environment>: the order terraform-aws-target-group v1 gives
  # the target group (and terraform-aws-secrets-vault v1 the secret). It is the ONE
  # exception to <project>-<environment>-<service>, which everything else here
  # follows, and goes when both modules release a v2.
  service_first_name = "${var.project_name}-${var.service_name}-${var.environment}"
  target_group_name  = "${local.service_first_name}-tg"

  # The one parameter through which the application repository learns about this
  # service. Written by this repository's role, read by the app repository's.
  parameter_name = "/${var.project_name}/services/${var.service_name}/config"

  # Where a dedicated service publishes what its own hosts read, and the document
  # it sends to redeploy them. Core's policy scopes both to this service's name.
  config_bucket        = "${var.project_name}-${var.environment}-${var.service_name}-config"
  update_document_name = "${var.project_name}-${var.service_name}-update"

  # Core owns the image and the deploy scripts even where the hosts are the
  # service's own, so that a fix is one rebuild and one upload rather than one
  # per service repository.
  ami_parameter              = try(local.platform.compute.ami_parameter, null)
  scripts_manifest_parameter = try(local.platform.compute.scripts_manifest_parameter, null)
  platform_prefix            = try(local.platform.compute.platform_prefix, "_platform")
  shared_deploy_bucket       = try(local.platform.buckets.deploy, null)

  # WHERE THE DATABASE IS depends on the hosting model:
  #
  #   shared      development. One EC2 database host runs every engine; the
  #               platforms team publishes each engine's port as an SSM parameter,
  #               which the application reads at deploy time.
  #   dedicated   staging, production. Each ACTIVE engine is its own managed
  #               instance, listed in the contract's database.engines with its
  #               host, port and provisioning function. An engine the environment
  #               does not run is simply absent, and the plan says so.
  managed_databases = try(local.platform.database.engines, {})
  managed_database  = var.database_engine == null ? null : try(local.managed_databases[var.database_engine], null)

  database_host = var.database_engine == null ? null : (
    local.is_dedicated ? try(local.managed_database.host, null) : try(local.platform.database.host, null)
  )

  # The port itself where the contract publishes it (managed); otherwise the
  # parameter the platforms team publishes it under.
  database_port           = local.is_dedicated ? try(local.managed_database.port, null) : null
  database_port_parameter = var.database_engine == null || local.is_dedicated ? null : "/${var.project_name}/database/engines/${var.database_engine}/port"

  # Provisioning: on the EC2 host this repository publishes a request, then sends
  # core's document to the host, which creates the database and user from the
  # secret. A managed database has no container to run that in, so core runs a
  # Lambda inside the VPC per engine, and this repository invokes that engine's.
  provision_document = var.database_engine == null || local.is_dedicated ? null : try(local.platform.database.provision_document, null)
  provision_function = var.database_engine == null || !local.is_dedicated ? null : try(local.managed_database.provision_function, null)

  provisioning_prefix = "provisioning/${var.service_name}"

  # Identifiers are the service name with underscores, which every supported
  # engine accepts unquoted.
  database_identifier = replace(var.service_name, "-", "_")

  # The service's agents: logins <database identifier>.<name>, at most 32
  # characters (MySQL's limit, which core holds on every engine).
  agent_logins     = { for name, agent in var.agents : name => "${local.database_identifier}.${name}" }
  agents_too_long  = [for name, login in local.agent_logins : login if length(login) > 32]
  agent_name_limit = 32 - length(local.database_identifier) - 1

  # Where the service declares its agents' emails to the front door. Null where
  # the platform has none (production).
  front_door_declaration_key = try(local.platform.team_front_door.declaration_prefix, null) == null ? null : "${local.platform.team_front_door.declaration_prefix}${var.service_name}.json"

  config = {
    schema_version = 1

    service_name  = var.service_name
    service_type  = var.service_type
    environment   = var.environment
    tier          = var.tier
    hosting_model = local.hosting_model

    domain            = local.domain
    port              = var.service_port
    health_check_path = var.health_check_path

    secret = {
      arn  = var.secret_arn
      name = var.secret_name
    }

    ecr = {
      repository_url  = var.ecr_repository_url
      repository_name = var.ecr_repository_name
    }

    target_group_arn = var.target_group_arn

    # Where the application repository publishes its compose file and .env, and
    # which document redeploys. On a shared fleet both belong to the tier; with
    # dedicated hosts both belong to this service alone.
    deploy = local.is_dedicated ? {
      bucket          = local.config_bucket
      prefix          = "services/${var.service_name}"
      update_document = local.update_document_name
      } : {
      bucket          = local.shared_deploy_bucket
      prefix          = "${var.tier}/${var.service_name}"
      update_document = try(local.platform.fleet_update_document, null)
    }

    static = {
      bucket = try(local.platform.buckets.assets, null)
      prefix = "static/${var.service_name}"
    }

    database = var.database_engine == null ? null : {
      engine = var.database_engine
      host   = local.database_host

      # Exactly one is set: port on a managed database, port_parameter on the EC2
      # host (read from SSM at deploy time).
      port           = local.database_port
      port_parameter = local.database_port_parameter
      secret_fields = {
        name     = "db_name"
        user     = "db_user"
        password = "db_password"
      }
    }
  }

  config_json = jsonencode(local.config)

  # What core's provisioning script reads. It names WHERE the credentials are, and
  # never contains one: the database host reads the secret itself.
  provisioning_request = var.database_engine == null ? null : {
    service_name         = var.service_name
    database_engine      = var.database_engine
    database_secrets_arn = var.secret_arn

    secret_mappings = {
      db_key   = "db_name"
      user_key = "db_user"
      pass_key = "db_password"
    }
  }

  provisioning_request_json = local.provisioning_request == null ? null : jsonencode(local.provisioning_request)
}
