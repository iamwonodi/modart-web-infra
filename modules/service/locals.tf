# What goes into the service's secret, and the tag core's policies condition on.
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
