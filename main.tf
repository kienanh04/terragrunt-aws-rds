provider "aws" {
  region  = "${var.aws_region}"
  profile = "${var.aws_profile}"
}

terraform {
  backend "s3" {}
}

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config {
    bucket         = "${var.tfstate_bucket}"
    key            = "${var.tfstate_key_vpc}"
    region         = "${var.tfstate_region}"
    profile        = "${var.tfstate_profile}"
    role_arn       = "${var.tfstate_arn}"
  }
}


data "aws_security_group" "rds" {
  tags = "${merge(var.source_security_group_tags,local.env_tags[var.enable_env_tags ? "enabled" : "not_enabled"])}"
}

locals {
  common_tags = {
    Env = "${var.project_env}"
  }

  env_tags    = {
    enabled     = { Env = "${var.project_env}" }
    not_enabled = {}
  }

  tags = "${merge(var.tags,local.common_tags)}"

  db_subnet_group_name          = "${coalesce(var.db_subnet_group_name, module.db_subnet_group.this_db_subnet_group_id)}"
  enable_create_db_subnet_group = "${var.db_subnet_group_name == "" ? var.create_db_subnet_group : false}"

  parameter_group_name    = "${coalesce(var.parameter_group_name, var.identifier)}"
  parameter_group_name_id = "${coalesce(var.parameter_group_name, module.db_parameter_group.this_db_parameter_group_id)}"

  option_group_name             = "${coalesce(var.option_group_name, module.db_option_group.this_db_option_group_id)}"
  enable_create_db_option_group = "${var.option_group_name == "" && var.engine != "postgres" ? var.create_db_option_group : false}"

  vpc_security_group_ids  = ["${data.aws_security_group.rds.id}"]
  
  subnets = "${split(",", var.created_database_subnets ? join(",",data.terraform_remote_state.vpc.database_subnets) : join(",",data.terraform_remote_state.vpc.private_subnets))}"

  common_name = "${var.namespace == "" ? "" : "${var.namespace}-"}${lower(var.project_env_short)}-rds-${lower(var.identifier)}"
  dns_name    = "${coalesce(var.customized_dns_name, local.common_name)}"

}

# RDS and resources:
module "db_subnet_group" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds.git//modules/db_subnet_group?ref=v1.32.0"

  create      = "${local.enable_create_db_subnet_group}"
  identifier  = "${var.identifier}"
  name_prefix = "${var.identifier}-"
  subnet_ids  = ["${local.subnets}"]

  tags = "${local.tags}"
}

module "db_parameter_group" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds.git//modules/db_parameter_group?ref=v1.32.0"

  create          = "${var.create_db_parameter_group}"
  identifier      = "${var.identifier}"
  name            = "${var.parameter_group_name}"
  description     = "${var.parameter_group_description}"
  name_prefix     = "${var.identifier}-"
  use_name_prefix = "${var.use_parameter_group_name_prefix}"
  family          = "${var.family}"

  parameters = ["${var.parameters}"]

  tags = "${local.tags}"
}

module "db_option_group" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds.git//modules/db_option_group?ref=v1.32.0"

  create                   = "${local.enable_create_db_option_group}"
  identifier               = "${var.identifier}"
  name_prefix              = "${var.identifier}-"
  option_group_description = "${var.option_group_description}"
  engine_name              = "${var.engine}"
  major_engine_version     = "${var.major_engine_version}"

  options = ["${var.options}"]

  tags = "${local.tags}"
}

module "db_instance" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds.git//modules/db_instance?ref=v1.32.0"

  create                = "${var.create_db_instance}"
  identifier            = "${var.identifier}"
  engine                = "${var.engine}"
  engine_version        = "${var.engine_version}"
  instance_class        = "${var.instance_class}"
  allocated_storage     = "${var.allocated_storage}"
  max_allocated_storage = "${var.max_allocated_storage}"
  storage_type          = "${var.storage_type}"
  storage_encrypted     = "${var.storage_encrypted}"
  kms_key_id            = "${var.kms_key_id}"
  license_model         = "${var.license_model}"

  name                                = "${var.name}"
  username                            = "${var.username}"
  password                            = "${var.password}"
  port                                = "${var.port}"
  iam_database_authentication_enabled = "${var.iam_database_authentication_enabled}"

  replicate_source_db = "${var.replicate_source_db}"

  snapshot_identifier = "${var.snapshot_identifier}"

  vpc_security_group_ids = ["${local.vpc_security_group_ids}"]
  db_subnet_group_name   = "${local.db_subnet_group_name}"
  parameter_group_name   = "${local.parameter_group_name_id}"
  option_group_name      = "${local.option_group_name}"

  availability_zone   = "${var.availability_zone}"
  multi_az            = "${var.multi_az}"
  iops                = "${var.iops}"
  publicly_accessible = "${var.publicly_accessible}"

  allow_major_version_upgrade = "${var.allow_major_version_upgrade}"
  auto_minor_version_upgrade  = "${var.auto_minor_version_upgrade}"
  apply_immediately           = "${var.apply_immediately}"
  maintenance_window          = "${var.maintenance_window}"
  skip_final_snapshot         = "${var.skip_final_snapshot}"
  copy_tags_to_snapshot       = "${var.copy_tags_to_snapshot}"
  final_snapshot_identifier   = "${var.final_snapshot_identifier}"

  performance_insights_enabled = "${var.performance_insights_enabled}"

  backup_retention_period = "${var.backup_retention_period}"
  backup_window           = "${var.backup_window}"

  ##monitoring_interval    = "${var.monitoring_interval}"
  ##monitoring_role_arn    = "${var.monitoring_role_arn}"
  ##monitoring_role_name   = "${var.monitoring_role_name}"
  ##create_monitoring_role = "${var.create_monitoring_role}"

  timezone                        = "${var.timezone}"
  character_set_name              = "${var.character_set_name}"
  enabled_cloudwatch_logs_exports = "${var.enabled_cloudwatch_logs_exports}"

  timeouts = "${var.timeouts}"

  deletion_protection = "${var.deletion_protection}"

  tags = "${local.tags}"
}

## DNS local:
resource "aws_route53_record" "endpoint" {
  count   = "${var.dns_private ? 1 : 0}"
  zone_id = "${data.terraform_remote_state.vpc.private_zone_id}"
  name    = "${local.dns_name}.${var.domain_local}"
  type    = "CNAME"
  ttl     = "60"
  records = ["${module.db_instance.this_db_instance_address}"]
}
