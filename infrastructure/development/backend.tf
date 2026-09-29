terraform {
  backend "s3" {
    # The environment's state bucket, created by core's bootstrap script. Named
    # <project>-<environment>-tfstate. Backend blocks cannot use variables, so
    # scripts/init-service.sh writes the three values below.
    bucket = "modart-development-tfstate"

    # Core's policy lets this repository's role read and write ONLY keys under
    # services/<service_name>/, so the key must stay in that shape.
    key = "services/web/terraform.tfstate"

    region       = "af-south-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB
  }
}
