locals {
  # <project>-<environment>-<service>: what this module names itself.
  name = "${var.project_name}-${var.environment}-${var.service_name}"

  # The service's secret is named by terraform-aws-secrets-vault v1, which puts the
  # service before the environment. The instance role may read exactly that name.
  # It follows the rule above once the module releases a v2.
  secret_prefix = "${var.project_name}-${var.service_name}-${var.environment}"

  # Core's generated policy lets this repository create IAM roles only under this
  # path, and only carrying the boundary and this tag.
  iam_path = "/services/${var.service_name}/"

  update_document_name = "${var.project_name}-${var.service_name}-update"

  application_root = "/opt/applications"

  # A dedicated host syncs one prefix, exactly as a shared fleet host does. Its
  # "tier" is services/, under which only this service has a directory -- so the
  # deploy engine core owns needs no change to run here.
  fleet_tier = "services"

  # Service is not decoration: core's policy lets this role's resources be created
  # and changed only while they carry it.
  tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      Service     = var.service_name
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

# ------------------------------------------------------------------------------
# What a host does at boot
#
# It installs core's platform scripts, verified against core's manifest, writes
# the runtime environment those scripts read, and runs one deploy. Nothing
# service-specific is baked in: the compose file and the .env come from the
# configuration bucket, so a host that scales out later gets exactly what the
# others are running rather than starting empty.
#
# FLEET_TIER is "services": a dedicated host syncs that one prefix of its own
# bucket, under which only this service has a directory. The deploy engine core
# owns therefore runs here unchanged.
# ------------------------------------------------------------------------------
locals {
  host_environment = <<-ENVIRONMENT
    PROJECT_NAME=${var.project_name}
    ENVIRONMENT=${var.environment}
    DEPLOY_BUCKET_NAME=${var.config_bucket}
    FLEET_TIER=${local.fleet_tier}
    AWS_REGION=${var.aws_region}
    ECR_REGISTRY_URL=${var.ecr_registry_url}
  ENVIRONMENT

  user_data = <<-BOOT
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p ${local.application_root}

    cat > ${local.application_root}/.env <<'HOST_ENVIRONMENT'
    ${trimspace(local.host_environment)}
    HOST_ENVIRONMENT

    # Install core's platform scripts, refusing anything whose checksum does not
    # match core's manifest. The manifest is an SSM parameter only core can write,
    # and the objects live in a bucket only core can write, so a tampered script
    # would have to defeat both.
    #
    # This repeats what core's own fetch helper does, in a dozen lines, rather
    # than depending on core's repository from here: a service repository has no
    # copy of it, and downloading the fetcher before it can be verified would only
    # move the question.
    manifest="$(aws ssm get-parameter \
      --name "${var.scripts_manifest_parameter}" \
      --query Parameter.Value --output text \
      --region "${var.aws_region}")"

    for key in $(echo "$${manifest}" | jq -r 'keys[]'); do
      expected="$(echo "$${manifest}" | jq -r --arg k "$${key}" '.[$k]')"
      destination="${local.application_root}/$(basename "$${key}")"

      aws s3 cp "s3://${var.platform_deploy_bucket}/$${key}" "$${destination}.new" \
        --region "${var.aws_region}" --only-show-errors

      actual="$(sha256sum "$${destination}.new" | cut -d' ' -f1)"

      if [ "$${actual}" != "$${expected}" ]; then
        echo "ERROR: $${key} does not match the platform manifest; refusing to install it." >&2
        rm -f "${local.application_root}"/*.new
        exit 1
      fi

      mv "$${destination}.new" "$${destination}"
      chmod +x "$${destination}"
    done

    # One deploy at boot, so a host that scales out is serving before the load
    # balancer's health check gives up on it.
    JITTER_SECONDS=0 ${local.application_root}/update.sh
  BOOT
}
