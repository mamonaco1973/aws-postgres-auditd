# ==============================================================================
# DATABASE PASSWORDS
# ==============================================================================
# Two generated passwords: the postgres superuser and audit_reader, the
# read-only login pgweb users sign in as. Alphanumeric only, so they survive
# shell quoting in cloud-init and copy-paste into pgweb.
# ==============================================================================

resource "random_password" "postgres_password" {
  length  = 24
  special = false
}

resource "random_password" "audit_reader_password" {
  length  = 24
  special = false
}

# ==============================================================================
# SECRETS MANAGER: auditd-postgres-credentials
# ==============================================================================
# One JSON secret holding both passwords. recovery_window_in_days = 0 deletes
# it immediately on destroy, so a redeploy doesn't collide with a secret that
# is still pending deletion.
# ==============================================================================

resource "aws_secretsmanager_secret" "auditd_credentials" {
  name                    = "auditd-postgres-credentials"
  description             = "PostgreSQL passwords for the auditd FDW lab"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "auditd_credentials_version" {
  secret_id = aws_secretsmanager_secret.auditd_credentials.id

  secret_string = jsonencode({
    postgres_user         = "postgres"
    postgres_password     = random_password.postgres_password.result
    audit_reader_user     = "audit_reader"
    audit_reader_password = random_password.audit_reader_password.result
    host                  = "localhost"
    port                  = 5432
    database              = "auditdb"
  })
}
