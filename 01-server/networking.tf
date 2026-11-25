# ==============================================================================
# VPC FOR THE AUDITD LAB
# ==============================================================================
# One small VPC with a single public subnet. Everything in this lab runs on one
# EC2 instance, so there is nothing to spread across availability zones.
# Names carry an "auditd-" prefix so this stack can sit next to aws-postgres in
# the same account without colliding.
# ==============================================================================

resource "aws_vpc" "auditd_vpc" {
  cidr_block = "10.0.0.0/24"

  # The instance's public DNS name is what validate.sh prints for pgweb.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "auditd-vpc"
  }
}

# ==============================================================================
# INTERNET GATEWAY AND PUBLIC ROUTING
# ==============================================================================
# The instance needs outbound internet for apt, git and the pgweb download, and
# inbound HTTP for the pgweb UI.
# ==============================================================================

resource "aws_internet_gateway" "auditd_igw" {
  vpc_id = aws_vpc.auditd_vpc.id

  tags = {
    Name = "auditd-igw"
  }
}

resource "aws_route_table" "auditd_public_rt" {
  vpc_id = aws_vpc.auditd_vpc.id

  tags = {
    Name = "auditd-public-rt"
  }
}

resource "aws_route" "auditd_default_route" {
  route_table_id         = aws_route_table.auditd_public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.auditd_igw.id
}

# ==============================================================================
# PUBLIC SUBNET
# ==============================================================================

resource "aws_subnet" "auditd_subnet" {
  vpc_id                  = aws_vpc.auditd_vpc.id
  cidr_block              = "10.0.0.0/26"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-2a"

  tags = {
    Name = "auditd-subnet-1"
  }
}

resource "aws_route_table_association" "auditd_public_rta" {
  subnet_id      = aws_subnet.auditd_subnet.id
  route_table_id = aws_route_table.auditd_public_rt.id
}
