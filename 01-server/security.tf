# ==============================================================================
# SECURITY GROUP: PGWEB (TCP/80 ONLY)
# ==============================================================================
# pgweb is the only thing exposed. There is deliberately no 5432 rule:
# PostgreSQL listens on localhost and is reached only through pgweb on the
# same host. Admin access is over SSM, so there is no SSH rule either.
# ==============================================================================

resource "aws_security_group" "auditd_http_sg" {
  name        = "auditd-http-sg"
  description = "Allow HTTP (80) inbound for pgweb and unrestricted egress."
  vpc_id      = aws_vpc.auditd_vpc.id

  # ----------------------------------------------------------------------------
  # INGRESS: HTTP (TCP/80) FROM ANYWHERE
  # ----------------------------------------------------------------------------
  # pgweb has no sign-in of its own; the database password is the only gate.
  # ----------------------------------------------------------------------------
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ----------------------------------------------------------------------------
  # EGRESS: ALL
  # ----------------------------------------------------------------------------
  # apt, GitHub and the SSM endpoints are all reached outbound.
  # ----------------------------------------------------------------------------
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "auditd-http-sg"
  }
}
