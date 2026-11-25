# ==============================================================================
# IAM ROLE: EC2 SYSTEMS MANAGER (SSM)
# ==============================================================================
# The instance has no SSH key; every admin step (validate.sh, the demo's
# generator runs, benchmarks) goes through SSM Session Manager or Run Command.
# ==============================================================================

# ------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.auditd_ssm_role
# ------------------------------------------------------------------------------
# Role assumable only by EC2.
# ------------------------------------------------------------------------------
resource "aws_iam_role" "auditd_ssm_role" {
  name = "auditd-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# ------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy_attachment.auditd_ssm_core
# ------------------------------------------------------------------------------
# AmazonSSMManagedInstanceCore is all Session Manager and Run Command need.
# The broader AmazonSSMFullAccess used in aws-postgres is left off on purpose.
# ------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "auditd_ssm_core" {
  role       = aws_iam_role.auditd_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ------------------------------------------------------------------------------
# RESOURCE: aws_iam_instance_profile.auditd_ssm_profile
# ------------------------------------------------------------------------------
resource "aws_iam_instance_profile" "auditd_ssm_profile" {
  name = "auditd-ec2-ssm-profile"
  role = aws_iam_role.auditd_ssm_role.name
}
