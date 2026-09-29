# ------------------------------------------------------------------------------
# SERVICE MODEL
#
# Everything that can be worked out about a service BEFORE any resource exists:
# what the platform offers, which tier resources the service attaches to, its
# names, and the document its application repository reads to deploy it. It
# creates no resources, so it is tested without AWS.
#
# Two hosting models, decided by the platform, not by this repository:
#
#   shared         development. Services share the tier's fleet; this service
#                  attaches its target group to it and publishes into the shared
#                  deploy bucket.
#   dedicated      staging, production. This service creates its OWN hosts, its
#                  own security group, its own configuration bucket and its own
#                  update document. Core still owns the image those hosts boot
#                  and the scripts they run.
#
# The invariants below stop the plan with a message naming the cause, instead of
# letting a wrong tier, a dedicated environment this blueprint does not yet host,
# or a name AWS would truncate reach the API.
# ------------------------------------------------------------------------------

resource "terraform_data" "model_invariants" {
  lifecycle {
    # Agents are logins on the service's database.
    precondition {
      condition     = length(var.agents) == 0 || var.database_engine != null
      error_message = "agents.json lists agents, but the service has no database: an agent is a login on the service's database."
    }

    precondition {
      condition     = length(local.agents_too_long) == 0
      error_message = "These logins are longer than 32 characters, MySQL's limit: ${join(", ", local.agents_too_long)}. With this service's name an agent's name can be at most ${local.agent_name_limit} characters."
    }

    precondition {
      condition     = try(local.platform.schema_version, null) == 1
      error_message = "This blueprint was written for platform contract version 1, but core publishes version ${try(local.platform.schema_version, "unknown")} at /${var.project_name}/platform/config."
    }

    precondition {
      condition     = contains(["shared", "dedicated"], coalesce(local.hosting_model, "unknown"))
      error_message = "The platform reports hosting_model \"${coalesce(local.hosting_model, "unknown")}\", which this blueprint does not know how to build for."
    }

    precondition {
      condition     = local.tier != null
      error_message = "The platform offers no tier \"${var.tier}\" in this environment. Available: ${join(", ", keys(try(local.platform.tiers, {})))}.${var.tier == "internal" ? " Core runs the internal tier only while internal_tier_enabled is on in that environment's terraform.tfvars." : ""}"
    }

    # A shared fleet needs the tier's own group and ASG to attach to. Dedicated
    # hosting needs the tier's subnets, and the tier's group for its own hosts to
    # wear: the databases and the Secrets Manager endpoint admit that group, not
    # the service's own.
    precondition {
      condition = local.tier != null && alltrue([
        for key in local.is_dedicated ? ["listener_arn", "alb_security_group_id", "security_group_id", "subnet_ids"] : ["listener_arn", "alb_security_group_id", "security_group_id", "asg_name"] :
        try(local.tier[key], null) != null
      ])
      error_message = "The platform's ${var.tier} tier is missing something this hosting model needs: ${local.is_dedicated ? "listener_arn, alb_security_group_id, security_group_id or subnet_ids. A core published before dedicated hosts wore the tier's security group lacks security_group_id: update and apply core first" : "listener_arn, alb_security_group_id, security_group_id or asg_name"}."
    }

    precondition {
      condition     = local.is_dedicated || (try(local.platform.buckets.deploy, null) != null && try(local.platform.fleet_update_document, null) != null)
      error_message = "The platform publishes no shared deploy bucket or fleet-update document, which the shared fleet needs."
    }

    # Dedicated hosts boot core's image and install core's scripts, so both must
    # be published before this service can build anything.
    precondition {
      condition     = !local.is_dedicated || (local.ami_parameter != null && local.scripts_manifest_parameter != null && local.shared_deploy_bucket != null)
      error_message = "This environment hosts services dedicated, but the platform publishes no golden image parameter, script manifest or deploy bucket for their hosts to use."
    }

    precondition {
      condition     = !local.is_dedicated || try(local.platform.service_boundary_arn, null) != null
      error_message = "This environment hosts services dedicated, so every IAM role this repository creates must carry the platform's permissions boundary -- and the platform publishes none."
    }

    precondition {
      condition     = length(local.target_group_name) <= 32
      error_message = "The target group name ${local.target_group_name} is ${length(local.target_group_name)} characters; AWS allows 32. Shorten project_name or service_name."
    }

    precondition {
      condition     = var.database_engine == null || local.is_dedicated || try(local.platform.database.host, null) != null
      error_message = "database_engine is ${coalesce(var.database_engine, "unset")}, but the platform publishes no database host."
    }

    # A managed environment runs only the engines core lists for it, each billed
    # while it runs. Failing here names the fix instead of deploying a service
    # that could never reach its database.
    precondition {
      condition     = var.database_engine == null || !local.is_dedicated || local.managed_database != null
      error_message = "database_engine is ${coalesce(var.database_engine, "unset")}, but ${var.environment} runs ${length(local.managed_databases) == 0 ? "no database engine" : "only: ${join(", ", sort(keys(local.managed_databases)))}"}. Add it to database_engines in core's infrastructure/${var.environment}/terraform.tfvars (scripts/init-project.sh --${var.environment}-engines), or use an engine this environment runs."
    }

    precondition {
      condition     = local.managed_database == null || (try(local.managed_database.host, null) != null && try(local.managed_database.port, null) != null)
      error_message = "The platform lists ${coalesce(var.database_engine, "unset")} for ${var.environment} without a host or port."
    }
  }
}
