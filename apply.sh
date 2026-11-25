#!/bin/bash
# ==============================================================================
# FILE: apply.sh
# ==============================================================================
# ORCHESTRATION SCRIPT: AUDITD FDW LAB DEPLOYMENT AND VALIDATION
# ==============================================================================
# Builds the lab (one Ubuntu 26.04 host running auditd, PostgreSQL 18 and
# pgweb) and waits until it has finished bootstrapping.
#
# High-level flow:
#   1) Validate local environment prerequisites.
#   2) Set the AWS default region for CLI and Terraform.
#   3) Provision the VPC, secret and server with Terraform.
#   4) Wait for cloud-init to finish and print the connection details.
#
# Notes:
# - This script is written to fail fast if any prerequisite step fails.
# - Terraform is executed non-interactively using auto-approve.
# ==============================================================================

# Enable strict shell behavior:
#   -e  Exit immediately on error
#   -u  Treat unset variables as errors
#   -o pipefail  Fail pipelines if any command fails
set -euo pipefail

# ==============================================================================
# STEP 0: ENVIRONMENT VALIDATION
# ==============================================================================
# Verify that all required tools, credentials, and environment variables
# are present before proceeding.
# ==============================================================================
# Abort immediately if the environment validation fails.
if ! ./check_env.sh; then
  echo "ERROR: Environment check failed. Exiting."
  exit 1
fi

# ==============================================================================
# STEP 1: SET AWS DEFAULT REGION
# ==============================================================================
# Export the AWS region used by Terraform and AWS CLI commands.
# ==============================================================================
# AWS_REGION is set too: the CLI gives it precedence over
# AWS_DEFAULT_REGION, so an inherited AWS_REGION would otherwise win.
export AWS_DEFAULT_REGION="us-east-2"
export AWS_REGION="us-east-2"

# ==============================================================================
# STEP 2: TERRAFORM - BUILD THE SERVER
# ==============================================================================
# One phase: network, IAM role, secret and the auditd-server instance.
# ==============================================================================
echo "NOTE: Building the auditd lab server."

# Change into the Terraform working directory.
cd 01-server

# Initialize Terraform backend and providers.
terraform init

# Apply Terraform configuration non-interactively.
terraform apply -auto-approve

# Return to the project root directory.
cd ..

# ==============================================================================
# STEP 3: POST-DEPLOYMENT VALIDATION
# ==============================================================================
# Wait for the bootstrap marker over SSM, then print the pgweb URL and how
# to fetch the password.
# ==============================================================================
./validate.sh
