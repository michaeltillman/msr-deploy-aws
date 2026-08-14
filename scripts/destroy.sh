#!/usr/bin/env bash
# Tear down all AWS resources created by deploy.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
SSH_KEY="$REPO_ROOT/keys/msr_ed25519"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: No valid AWS session. Run 'aws login' and retry." >&2
  exit 1
fi

terraform -chdir="$TF_DIR" destroy -input=false -auto-approve \
  -var "ssh_public_key_path=$SSH_KEY.pub"

echo "All AWS resources destroyed. Local state/credentials remain in .deploy/ and keys/ — delete them if you're done:"
echo "  rm -rf $REPO_ROOT/.deploy $REPO_ROOT/keys"
