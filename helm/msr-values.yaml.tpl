# MSR 4.13 Helm values template — rendered by scripts/deploy.sh.
# Placeholders (__EXTERNAL_IP__, __HTTPS_NODEPORT__, __ADMIN_PASSWORD__, __SECRET_KEY__)
# are substituted at deploy time; the rendered file lives in .deploy/ and is never committed.
#
# Values keys per https://docs.mirantis.com/msr/4.13/installation/msr-helm-install/

expose:
  type: nodePort
  tls:
    enabled: true
    certSource: auto
    auto:
      commonName: "__EXTERNAL_IP__"
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: 30002
      https:
        port: 443
        nodePort: __HTTPS_NODEPORT__

externalURL: https://__EXTERNAL_IP__:__HTTPS_NODEPORT__

# Set at deploy time; never committed. Chart default is Harbor12345.
harborAdminPassword: "__ADMIN_PASSWORD__"

# 16-character master encryption key. Immutable after first deploy
# (changing it breaks decryption of stored secrets/replication credentials).
secretKey: "__SECRET_KEY__"

persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:
      size: 20Gi
    jobservice:
      jobLog:
        size: 1Gi
    database:
      size: 5Gi
    redis:
      size: 1Gi
    trivy:
      size: 5Gi

# Internal single-replica services — the documented single-host demo layout.
database:
  type: internal
# Cache: chart key is `redis:` even though the internal implementation is Valkey (MSR 4.13 migrated from Redis).
redis:
  type: internal
portal:
  replicas: 1
core:
  replicas: 1
jobservice:
  replicas: 1
registry:
  replicas: 1
trivy:
  enabled: true
  replicas: 1

metrics:
  enabled: true
