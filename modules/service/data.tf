# The platform contract core publishes for this environment.
data "aws_ssm_parameter" "platform" {
  name = "/${var.project_name}/platform/config"
}
