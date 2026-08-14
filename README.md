# msr-deploy-aws

Automated deployment of **Mirantis Secure Registry (MSR) 4.13** into AWS, validated end to end.

MSR 4 is Mirantis' hardened distribution of CNCF Harbor (MSR 4.13.6 = Harbor 2.13.2), installed
from the public Helm chart `oci://registry.mirantis.com/harbor/helm/msr` — no license file or
registry credentials are required (per the
[MSR 4.13 installation guide](https://docs.mirantis.com/msr/4.13/installation/)).

## What gets deployed

```
AWS us-east-2
└── VPC 10.42.0.0/16
    └── public subnet ── EC2 t3.xlarge (Ubuntu 24.04, 100 GiB gp3, Elastic IP)
        └── k0s v1.32 (single node)          ← Kubernetes 1.31–1.32 per MSR compat matrix
            ├── local-path-provisioner       ← default StorageClass for MSR's 5 PVCs
            └── MSR 4.13.6 (Helm, ns "msr")
                ├── nginx proxy · portal · core · jobservice · registry · trivy
                ├── PostgreSQL (internal) · Valkey cache (internal)
                └── exposed via NodePort 30003 (HTTPS, auto-generated TLS cert)
```

This is the documented **single-host layout** (`expose.type: nodePort`, internal database/cache,
1 replica per component) — sized per the docs' recommended 4 CPU / 8 GB+ / 100 GB. It is a
dev/test topology; for production MSR requires HA (external PostgreSQL + Valkey, RWX storage,
2+ replicas — see the [HA install guide](https://docs.mirantis.com/msr/4.13/installation/installation-with-high-availability/)).

## Security model — nothing sensitive in this repo

This repo is public, so **no secrets are ever committed**:

- **AWS credentials** — never stored; every script starts with an `aws sts get-caller-identity`
  check against your ambient session. Run `aws login` before deploying.
- **SSH key pair** — generated locally into `keys/` on first deploy (gitignored).
- **MSR admin password & secretKey** — generated locally into `.deploy/msr-credentials.env`
  (gitignored, mode 0600). The chart's defaults (`Harbor12345` / `not-a-secure-key`) are never used.
- **Terraform state** — local only, gitignored.
- **Network** — the security group only admits the deployer's public IP (auto-detected),
  on ports 22 (SSH) and 30003 (MSR HTTPS). Override with `-var allowed_cidr=...`.

## Usage

```bash
aws login                # authenticate (session credentials only, never stored)
./scripts/deploy.sh      # provision + install + validate (~10-15 min)
```

`deploy.sh` finishes by running `./scripts/validate.sh`, which verifies:

1. `GET /api/v2.0/health` — every component (core, database, redis/valkey, registry, jobservice, portal, trivy) healthy
2. `GET /api/v2.0/systeminfo` — version reachable anonymously
3. Authenticated admin API call
4. Project creation (`msr-validation`)
5. A real OCI image push **and** pull through the registry token flow (what `docker login`/`push` does)
6. Trivy registered as the default vulnerability scanner
7. The web UI serves the portal

Then log in: the script prints the URL (`https://<elastic-ip>:30003`) — user `admin`, password in
`.deploy/msr-credentials.env`. The TLS certificate is chart-auto-generated (self-signed), so your
browser will warn once; for `docker login`, trust the CA per the
[docs](https://docs.mirantis.com/msr/4.13/installation/msr-helm-install/): place `tls.crt` at
`/etc/docker/certs.d/<ip>:30003/ca.crt`.

Tear down everything:

```bash
./scripts/destroy.sh
```

## Repo layout

| Path | Purpose |
|---|---|
| `terraform/` | VPC, security group, EC2 node with cloud-init k0s bootstrap |
| `helm/msr-values.yaml.tpl` | MSR chart values template (placeholders filled at deploy time) |
| `scripts/deploy.sh` | End-to-end: preflight → terraform → wait for k0s → helm install → validate |
| `scripts/validate.sh` | 7-point operational validation (rerunnable any time) |
| `scripts/destroy.sh` | `terraform destroy` |

## Notes from the MSR 4.13 docs worth knowing

- `secretKey` (16 chars) encrypts data at rest and **must never change** after first deploy.
- The chart's cache values key is `redis:` even though MSR 4.13 ships Valkey internally.
- Chart version == MSR version; pin with `MSR_VERSION=4.13.x ./scripts/deploy.sh`.
- Compatibility: Kubernetes 1.31–1.32, Helm 3.8+.
