#!/bin/bash
# ==============================================================================
# FILE: destroy.sh
# ==============================================================================
# ORCHESTRATION SCRIPT: AUDITD FDW LAB TEARDOWN
# ==============================================================================
# Destroys everything apply.sh built. The secret is deleted immediately
# (recovery_window_in_days = 0), so a redeploy can reuse its name.
#
# High-level flow:
#   1) Set the AWS default region for CLI and Terraform.
#   2) Initialize Terraform in 01-server.
#   3) Destroy all managed resources non-interactively.
#
# Notes:
# - This script assumes the infrastructure was created via Terraform.
# - Resources are destroyed without confirmation using auto-approve.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# SET AWS DEFAULT REGION
# ==============================================================================
# Export the AWS region used by Terraform and AWS CLI commands.
# ==============================================================================
# AWS_REGION is set too: the CLI gives it precedence over
# AWS_DEFAULT_REGION, so an inherited AWS_REGION would otherwise win.
export AWS_DEFAULT_REGION="us-east-2"
export AWS_REGION="us-east-2"

# ==============================================================================
# STEP 1: DESTROY THE LAB
# ==============================================================================
# Tear down the server, network, IAM role and secret.
# ==============================================================================

# Change into the Terraform working directory.
cd 01-server

# Initialize Terraform backend and providers.
terraform init

# Destroy Terraform-managed resources non-interactively.
terraform destroy -auto-approve

# Return to the project root directory.
cd ..
