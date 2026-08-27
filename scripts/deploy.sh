#!/usr/bin/env bash
# Deploy Mirantis Secure Registry (MSR) 4.13 onto a single-node k0s cluster in AWS.
#
# No secrets live in this repo. AWS credentials come from your ambient session
# (run `aws login` first); the SSH key and MSR admin password are generated
# locally into gitignored directories (keys/, .deploy/).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
DEPLOY_DIR="$REPO_ROOT/.deploy"
KEY_DIR="$REPO_ROOT/keys"
SSH_KEY="$KEY_DIR/msr_ed25519"

MSR_VERSION="${MSR_VERSION:-4.13.6}"
MSR_NAMESPACE="msr"
HTTPS_NODEPORT="${HTTPS_NODEPORT:-30003}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
log "Preflight checks"
for tool in aws terraform ssh-keygen openssl; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  die "No valid AWS session. Run 'aws login' and retry."
fi
aws sts get-caller-identity --query Arn --output text

# Terraform's AWS SDK cannot read `aws login` browser-session credentials directly;
# export them as ephemeral environment variables for this process only.
eval "$(aws configure export-credentials --format env)"

mkdir -p "$DEPLOY_DIR" "$KEY_DIR"

# --- SSH key (generated locally, never committed) ----------------------------
if [[ ! -f "$SSH_KEY" ]]; then
  log "Generating SSH key pair"
  ssh-keygen -t ed25519 -N "" -C "msr-deploy-aws" -f "$SSH_KEY"
fi

# --- Terraform: VPC + EC2 + k0s bootstrap ------------------------------------
log "Provisioning AWS infrastructure (us-east-2)"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
terraform -chdir="$TF_DIR" apply -input=false -auto-approve \
  -var "ssh_public_key_path=$SSH_KEY.pub" \
  -var "msr_https_nodeport=$HTTPS_NODEPORT"

EXTERNAL_IP="$(terraform -chdir="$TF_DIR" output -raw public_ip)"
MSR_URL="https://$EXTERNAL_IP:$HTTPS_NODEPORT"
log "Node public IP: $EXTERNAL_IP"

# Terraform may have replaced the node (new host key, same EIP); drop any stale pin.
ssh-keygen -R "$EXTERNAL_IP" -f "$DEPLOY_DIR/known_hosts" >/dev/null 2>&1 || true

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$DEPLOY_DIR/known_hosts" -o ConnectTimeout=10)
node_ssh() { ssh "${SSH_OPTS[@]}" "ubuntu@$EXTERNAL_IP" "$@"; }

# --- Wait for k0s bootstrap (cloud-init) --------------------------------------
log "Waiting for k0s bootstrap to complete (~3-5 min)"
for i in $(seq 1 60); do
  if node_ssh 'test -f /home/ubuntu/.bootstrap-complete' 2>/dev/null; then
    break
  fi
  [[ $i -eq 60 ]] && die "Node bootstrap did not complete in time. Check /var/log/msr-bootstrap.log on the node."
  sleep 10
done
node_ssh 'kubectl get nodes'

# --- Generate MSR credentials (locally, gitignored) ---------------------------
CREDS_FILE="$DEPLOY_DIR/msr-credentials.env"
if [[ -f "$CREDS_FILE" ]]; then
  # Reuse existing credentials (secretKey must never change for a given data set)
  # shellcheck disable=SC1090
  source "$CREDS_FILE"
else
  log "Generating MSR admin password and secretKey"
  MSR_ADMIN_PASSWORD="$(openssl rand -hex 12)"
  # secretKey must be exactly 16 characters and NEVER change after first deploy
  MSR_SECRET_KEY="$(openssl rand -hex 8)"
fi
# Rewrite every run: the Elastic IP changes when the stack is destroyed/recreated.
cat > "$CREDS_FILE" <<EOF
MSR_URL=$MSR_URL
MSR_ADMIN_USER=admin
MSR_ADMIN_PASSWORD=$MSR_ADMIN_PASSWORD
MSR_SECRET_KEY=$MSR_SECRET_KEY
EOF
chmod 0600 "$CREDS_FILE"

# --- Render Helm values -------------------------------------------------------
log "Rendering Helm values"
VALUES_FILE="$DEPLOY_DIR/msr-values.yaml"
sed -e "s/__EXTERNAL_IP__/$EXTERNAL_IP/g" \
    -e "s/__HTTPS_NODEPORT__/$HTTPS_NODEPORT/g" \
    -e "s/__ADMIN_PASSWORD__/$MSR_ADMIN_PASSWORD/g" \
    -e "s/__SECRET_KEY__/$MSR_SECRET_KEY/g" \
    "$REPO_ROOT/helm/msr-values.yaml.tpl" > "$VALUES_FILE"
chmod 0600 "$VALUES_FILE"

# --- Install MSR via Helm on the node -----------------------------------------
log "Installing MSR $MSR_VERSION (oci://registry.mirantis.com/harbor/helm/msr)"
scp "${SSH_OPTS[@]}" "$VALUES_FILE" "ubuntu@$EXTERNAL_IP:/home/ubuntu/msr-values.yaml"
node_ssh "chmod 0600 /home/ubuntu/msr-values.yaml && \
  helm upgrade --install msr oci://registry.mirantis.com/harbor/helm/msr \
    --version $MSR_VERSION \
    --namespace $MSR_NAMESPACE --create-namespace \
    -f /home/ubuntu/msr-values.yaml \
    --wait --timeout 20m"

node_ssh "kubectl -n $MSR_NAMESPACE get pods -o wide"

log "MSR deployed"
echo
echo "  UI:       $MSR_URL"
echo "  User:     admin"
echo "  Password: (see $CREDS_FILE)"
echo
log "Running validation"
"$REPO_ROOT/scripts/validate.sh"
