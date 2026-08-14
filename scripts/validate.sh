#!/usr/bin/env bash
# Validate a deployed MSR 4.13 instance end to end:
#   1. /api/v2.0/health        — every component healthy
#   2. /api/v2.0/systeminfo    — version info
#   3. authenticated API call  — admin credentials work
#   4. project creation        — write path through core + postgres
#   5. OCI image push/pull     — full docker-login token flow + registry blob store
#   6. Trivy scanner registered
#   7. web UI serves the portal
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS_FILE="$REPO_ROOT/.deploy/msr-credentials.env"
[[ -f "$CREDS_FILE" ]] || { echo "ERROR: $CREDS_FILE not found — deploy first."; exit 1; }
# shellcheck disable=SC1090
source "$CREDS_FILE"

BASE="$MSR_URL"
AUTH=(-u "$MSR_ADMIN_USER:$MSR_ADMIN_PASSWORD")
CURL=(curl -ks --connect-timeout 10)
PROJECT="msr-validation"
REPO="smoke"
TAG="v1"

PASS=0; FAIL=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

sha256() { openssl dgst -sha256 -hex | awk '{print $NF}'; }

# --- 1. Health (retry: components can take a minute after helm --wait) --------
log "Health check ($BASE/api/v2.0/health)"
HEALTHY=""
for i in $(seq 1 30); do
  HEALTH_JSON="$("${CURL[@]}" "$BASE/api/v2.0/health" || true)"
  if [[ "$(jq -r '.status // empty' <<<"$HEALTH_JSON" 2>/dev/null)" == "healthy" ]]; then
    HEALTHY=yes; break
  fi
  sleep 10
done
if [[ -n "$HEALTHY" ]]; then
  ok "overall status healthy"
  jq -r '.components[] | "       \(.name): \(.status)"' <<<"$HEALTH_JSON"
  UNHEALTHY="$(jq -r '[.components[] | select(.status != "healthy")] | length' <<<"$HEALTH_JSON")"
  [[ "$UNHEALTHY" == "0" ]] && ok "all components healthy" || bad "$UNHEALTHY component(s) unhealthy"
else
  bad "health endpoint never reported healthy; last: $HEALTH_JSON"
fi

# --- 2. System info ------------------------------------------------------------
log "System info"
SYSINFO="$("${CURL[@]}" "${AUTH[@]}" "$BASE/api/v2.0/systeminfo")"
HARBOR_VERSION="$(jq -r '.harbor_version // empty' <<<"$SYSINFO")"
[[ -n "$HARBOR_VERSION" ]] && ok "reachable, version: $HARBOR_VERSION" || bad "no harbor_version in systeminfo: $SYSINFO"

# --- 3. Authenticated API call ---------------------------------------------------
log "Admin authentication"
CODE="$("${CURL[@]}" "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE/api/v2.0/projects")"
[[ "$CODE" == "200" ]] && ok "admin API auth (HTTP $CODE)" || bad "admin API auth returned HTTP $CODE"

# --- 4. Project creation ----------------------------------------------------------
log "Project creation ($PROJECT)"
CODE="$("${CURL[@]}" "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"project_name\":\"$PROJECT\",\"public\":false}" \
  "$BASE/api/v2.0/projects")"
if [[ "$CODE" == "201" ]]; then ok "project created"
elif [[ "$CODE" == "409" ]]; then ok "project already exists"
else bad "project creation returned HTTP $CODE"; fi

# --- 5. OCI push/pull via registry API (same token flow docker login uses) -------
log "Image push/pull ($PROJECT/$REPO:$TAG)"
TOKEN="$("${CURL[@]}" "${AUTH[@]}" \
  "$BASE/service/token?service=harbor-registry&scope=repository:$PROJECT/$REPO:pull,push" \
  | jq -r '.token // empty')"
if [[ -n "$TOKEN" ]]; then
  ok "registry token issued (docker-login flow)"
  BEARER=(-H "Authorization: Bearer $TOKEN")

  CONFIG='{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[]}}'
  CONFIG_DIGEST="sha256:$(printf '%s' "$CONFIG" | sha256)"
  CONFIG_SIZE="$(printf '%s' "$CONFIG" | wc -c | tr -d ' ')"

  UPLOAD_URL="$("${CURL[@]}" "${BEARER[@]}" -X POST -D - -o /dev/null \
    "$BASE/v2/$PROJECT/$REPO/blobs/uploads/" \
    | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r')"
  [[ "$UPLOAD_URL" != /* ]] || UPLOAD_URL="$BASE$UPLOAD_URL"
  SEP='?'; [[ "$UPLOAD_URL" == *\?* ]] && SEP='&'
  CODE="$("${CURL[@]}" "${BEARER[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/octet-stream' \
    --data-binary "$CONFIG" "$UPLOAD_URL${SEP}digest=$CONFIG_DIGEST")"
  [[ "$CODE" == "201" ]] && ok "config blob pushed" || bad "blob push returned HTTP $CODE"

  MANIFEST="$(jq -nc --arg d "$CONFIG_DIGEST" --argjson s "$CONFIG_SIZE" \
    '{schemaVersion:2, mediaType:"application/vnd.oci.image.manifest.v1+json",
      config:{mediaType:"application/vnd.oci.image.config.v1+json", digest:$d, size:$s},
      layers:[]}')"
  CODE="$("${CURL[@]}" "${BEARER[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary "$MANIFEST" "$BASE/v2/$PROJECT/$REPO/manifests/$TAG")"
  [[ "$CODE" == "201" ]] && ok "manifest pushed (image push complete)" || bad "manifest push returned HTTP $CODE"

  CODE="$("${CURL[@]}" "${BEARER[@]}" -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "$BASE/v2/$PROJECT/$REPO/manifests/$TAG")"
  [[ "$CODE" == "200" ]] && ok "manifest pulled back" || bad "manifest pull returned HTTP $CODE"

  COUNT="$("${CURL[@]}" "${AUTH[@]}" "$BASE/api/v2.0/projects/$PROJECT/repositories" \
    | jq -r --arg r "$PROJECT/$REPO" '[.[] | select(.name==$r)] | length')"
  [[ "$COUNT" == "1" ]] && ok "repository visible in MSR API" || bad "repository not listed in MSR API"
else
  bad "no registry token issued"
fi

# --- 6. Trivy scanner -----------------------------------------------------------
log "Vulnerability scanner"
SCANNER="$("${CURL[@]}" "${AUTH[@]}" "$BASE/api/v2.0/scanners" \
  | jq -r '.[] | select(.name=="Trivy") | "\(.name) default=\(.is_default) health=\(.health)"')"
[[ -n "$SCANNER" ]] && ok "Trivy registered: $SCANNER" || bad "Trivy scanner not found"

# --- 7. Web UI -------------------------------------------------------------------
log "Web UI"
UI="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/")"
TITLE="$("${CURL[@]}" "$BASE/" | grep -o '<title>[^<]*</title>' || true)"
if [[ "$UI" == "200" && "$TITLE" == *"Mirantis Secure Registry"* ]]; then
  ok "portal serves the UI (HTTP $UI, $TITLE)"
else
  bad "UI check: HTTP $UI $TITLE"
fi

# UI session login — the same CSRF-token flow the browser login form uses
JAR="$(mktemp)"
CSRF="$("${CURL[@]}" -c "$JAR" -D - -o /dev/null "$BASE/c/login" \
  | awk 'tolower($1)=="x-harbor-csrf-token:"{print $2}' | tr -d '\r')"
CODE="$("${CURL[@]}" -b "$JAR" -c "$JAR" -H "X-Harbor-CSRF-Token: $CSRF" \
  -o /dev/null -w '%{http_code}' -X POST "$BASE/c/login" \
  --data-urlencode "principal=$MSR_ADMIN_USER" \
  --data-urlencode "password=$MSR_ADMIN_PASSWORD")"
WHOAMI="$("${CURL[@]}" -b "$JAR" "$BASE/api/v2.0/users/current" | jq -r '.username // empty')"
rm -f "$JAR"
if [[ "$CODE" == "200" && "$WHOAMI" == "$MSR_ADMIN_USER" ]]; then
  ok "UI session login works (logged in as $WHOAMI)"
else
  bad "UI session login: HTTP $CODE, user='$WHOAMI'"
fi

# --- Summary ---------------------------------------------------------------------
echo
printf '\033[1;36m==> Validation summary: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "MSR is operational: $BASE (admin credentials in .deploy/msr-credentials.env)"
