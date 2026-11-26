#!/bin/bash
# ==============================================================================
# FILE: validate.sh
# ==============================================================================
# PURPOSE:
#   Waits for the auditd lab server to finish bootstrapping, then prints the
#   pgweb URL and the audit_reader connection settings, password included.
#
# WHAT THIS SCRIPT DOES:
#   1) Looks up the running EC2 instance tagged Name=auditd-server.
#   2) Waits for it to register with SSM.
#   3) Polls over SSM Run Command for /root/bootstrap.done, the marker
#      written as the last step of cloud-init (packages, PostgreSQL schema,
#      pgweb, seeded demo events), with a timeout.
#   4) Prints the results.
#
# SSM rather than HTTP: pgweb answers on port 80 well before the database
# schema and demo events are in place, so a 200 from pgweb proves little.
#
# PREREQUISITES:
#   - AWS CLI with ec2:DescribeInstances, ssm:SendCommand,
#     ssm:GetCommandInvocation, ssm:DescribeInstanceInformation,
#     secretsmanager:GetSecretValue
#   - jq
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------------------------
AWS_REGION="us-east-2"
INSTANCE_NAME="auditd-server"
SECRET_ID="auditd-postgres-credentials"
POLL=15
SSM_TIMEOUT=600
BOOT_TIMEOUT=1200

# ------------------------------------------------------------------------------
# FUNCTION: find_instance
# ------------------------------------------------------------------------------
# Prints "<instance-id> <public-dns>" for the running auditd-server.
# ------------------------------------------------------------------------------
find_instance() {
  aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].[InstanceId,PublicDnsName]' \
    --output text
}

# ------------------------------------------------------------------------------
# FUNCTION: run_onbox ID COMMAND
# ------------------------------------------------------------------------------
# Runs one shell command over SSM and prints its stdout.
# ------------------------------------------------------------------------------
run_onbox() {
  local id="$1" cmd="$2" cid params
  params=$(jq -nc --arg c "$cmd" '{commands:[$c]}')
  cid=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$id" \
    --document-name "AWS-RunShellScript" --parameters "$params" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --region "$AWS_REGION" \
    --command-id "$cid" --instance-id "$id" >/dev/null 2>&1 || true
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cid" --instance-id "$id" \
    --query 'StandardOutputContent' --output text
}

read -r INSTANCE_ID PUBLIC_DNS < <(find_instance)
if [[ -z "${INSTANCE_ID:-}" || "$INSTANCE_ID" == "None" ]]; then
  echo "ERROR: no running instance tagged ${INSTANCE_NAME}"
  exit 1
fi

# ------------------------------------------------------------------------------
# WAIT FOR SSM REGISTRATION
# ------------------------------------------------------------------------------
elapsed=0
while true; do
  status=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text \
    2>/dev/null || echo None)
  [ "$status" = "Online" ] && break
  if [ "$elapsed" -ge "$SSM_TIMEOUT" ]; then
    echo "ERROR: ${INSTANCE_ID} not online in SSM after ${SSM_TIMEOUT}s"
    exit 1
  fi
  echo "NOTE: waiting for ${INSTANCE_ID} to register with SSM (${elapsed}s)..."
  sleep "$POLL"
  elapsed=$((elapsed + POLL))
done

# ------------------------------------------------------------------------------
# WAIT FOR THE BOOTSTRAP MARKER
# ------------------------------------------------------------------------------
elapsed=0
while true; do
  out=$(run_onbox "$INSTANCE_ID" \
    'test -f /root/bootstrap.done && echo DONE || tail -1 /root/userdata.log 2>/dev/null' \
    || true)
  [[ "$out" == DONE* ]] && break
  if [ "$elapsed" -ge "$BOOT_TIMEOUT" ]; then
    echo "ERROR: bootstrap not finished after ${BOOT_TIMEOUT}s."
    echo "       aws ssm start-session --target ${INSTANCE_ID}, then"
    echo "       sudo tail -50 /root/userdata.log"
    exit 1
  fi
  echo "NOTE: bootstrap running (${elapsed}s): ${out:0:70}"
  sleep "$POLL"
  elapsed=$((elapsed + POLL))
done

# ------------------------------------------------------------------------------
# READ THE PASSWORD
# ------------------------------------------------------------------------------
# Print the password outright rather than sending the user off to look it
# up. Secrets Manager stays the source of truth; this just reads it back.
# ------------------------------------------------------------------------------
CREDS_JSON=$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$SECRET_ID" --query SecretString --output text \
  2>/dev/null || true)
if [ -n "$CREDS_JSON" ]; then
  PASSWORD=$(jq -r .audit_reader_password <<<"$CREDS_JSON")
else
  # Usually the caller lacks secretsmanager:GetSecretValue. Fall back to
  # showing the lookup command.
  PASSWORD="<unavailable> - run: aws secretsmanager get-secret-value"
  PASSWORD+=" --region ${AWS_REGION} --secret-id ${SECRET_ID}"
  PASSWORD+=" --query SecretString --output text | jq -r .audit_reader_password"
fi

# ------------------------------------------------------------------------------
# DISPLAY RESULTS
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo " aws-postgres-auditd - Quick Start"
echo "=========================================================================="
echo ""
printf "%-24s %s\n" "NOTE: pgweb URL:"   "http://${PUBLIC_DNS}"
printf "%-24s %s\n" "NOTE: Instance ID:" "${INSTANCE_ID}"
echo ""
printf "%-24s %s\n" "NOTE: Host:"        "localhost"
printf "%-24s %s\n" "NOTE: Port:"        "5432"
printf "%-24s %s\n" "NOTE: Database:"    "auditdb"
printf "%-24s %s\n" "NOTE: Username:"    "audit_reader"
printf "%-24s %s\n" "NOTE: Password:"    "${PASSWORD}"
printf "%-24s %s\n" "NOTE: SSL mode:"    "disable"
echo ""
printf "%-24s %s\n" "NOTE: Server shell:" \
  "aws ssm start-session --region ${AWS_REGION} --target ${INSTANCE_ID}"
echo ""
