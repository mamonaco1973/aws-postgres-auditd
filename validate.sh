#!/bin/bash
# ==============================================================================
# FILE: validate.sh
# ==============================================================================
# PURPOSE:
#   Waits for the auditd lab server to finish bootstrapping, then prints the
#   pgweb URL, the connection settings, and the command that fetches the
#   audit_reader password.
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
#     ssm:GetCommandInvocation, ssm:DescribeInstanceInformation
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
# DISPLAY RESULTS
# ------------------------------------------------------------------------------
echo "=========================================================================="
echo " PROJECT ENDPOINTS"
echo "=========================================================================="
echo
echo " PGWEB Application:"
echo "   http://${PUBLIC_DNS}"
echo
echo " Connect with:"
echo "   Host localhost   Port 5432   Database auditdb"
echo "   User audit_reader   SSL mode disable"
echo
echo " Password:"
echo "   aws secretsmanager get-secret-value --region ${AWS_REGION} \\"
echo "     --secret-id ${SECRET_ID} --query SecretString --output text \\"
echo "     | jq -r .audit_reader_password"
echo
echo " Shell on the server:"
echo "   aws ssm start-session --region ${AWS_REGION} --target ${INSTANCE_ID}"
echo
echo "=========================================================================="
