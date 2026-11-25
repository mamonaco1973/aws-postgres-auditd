# ==============================================================================
# UBUNTU 26.04 (RESOLUTE) AMI
# ==============================================================================
# Newest Canonical-published 26.04 server image. Owner is pinned to Canonical
# so a look-alike public AMI can never be picked up by the name filter.
# ==============================================================================

data "aws_ami" "ubuntu_2604" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ==============================================================================
# RESOURCE: AUDITD SERVER
# ==============================================================================
# One host runs auditd, PostgreSQL 18 and pgweb. PostgreSQL reads the audit
# logs from local disk, which is exactly what a managed database can't do.
# ==============================================================================

resource "aws_instance" "auditd_server" {

  # ----------------------------------------------------------------------------
  # AMI AND INSTANCE TYPE
  # ----------------------------------------------------------------------------
  # m7i.large is fixed-performance on purpose: burstable t3 CPU credits would
  # run out halfway through the benchmarks and distort the numbers.
  # ----------------------------------------------------------------------------
  ami           = data.aws_ami.ubuntu_2604.id
  instance_type = "m7i.large"

  # ----------------------------------------------------------------------------
  # ROOT DISK
  # ----------------------------------------------------------------------------
  # 60 GB holds the 10M-record benchmark corpus (raw and compressed) plus the
  # native tables and indexes loaded from it.
  # ----------------------------------------------------------------------------
  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  # ----------------------------------------------------------------------------
  # NETWORKING
  # ----------------------------------------------------------------------------
  subnet_id                   = aws_subnet.auditd_subnet.id
  vpc_security_group_ids      = [aws_security_group.auditd_http_sg.id]
  associate_public_ip_address = true

  # ----------------------------------------------------------------------------
  # IAM / SSM ACCESS
  # ----------------------------------------------------------------------------
  # No key pair: shell access is SSM only.
  # ----------------------------------------------------------------------------
  iam_instance_profile = aws_iam_instance_profile.auditd_ssm_profile.name

  # ----------------------------------------------------------------------------
  # USER DATA
  # ----------------------------------------------------------------------------
  # The passwords are injected here, the same way aws-postgres does it. Anyone
  # with ec2:DescribeInstanceAttribute can read them: acceptable for a lab.
  # ----------------------------------------------------------------------------
  user_data = templatefile("${path.module}/scripts/install_server.sh", {
    POSTGRES_PASSWORD     = random_password.postgres_password.result
    AUDIT_READER_PASSWORD = random_password.audit_reader_password.result
    REPO_URL              = "https://github.com/mamonaco1973/aws-postgres-auditd.git"
  })

  # Re-run cloud-init on a new instance when the bootstrap script changes.
  user_data_replace_on_change = true

  tags = {
    Name = "auditd-server"
  }

  # The route must exist before boot, or apt and git clone fail on first try.
  depends_on = [aws_route.auditd_default_route]
}

# ==============================================================================
# OUTPUTS
# ==============================================================================
# validate.sh and the bench helpers address the instance by ID over SSM.
# ==============================================================================

output "instance_id" {
  value = aws_instance.auditd_server.id
}

output "public_dns" {
  value = aws_instance.auditd_server.public_dns
}
