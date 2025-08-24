#!/usr/bin/env bash
set -euo pipefail
: "${IAP_ANY:=}"
#############################################
# This file must be executed from the same folder where "backend" and "frontend"
# folders exist
#############################################

#############################################
# Config — EDIT THESE
#############################################
PROJECT_ID="ls-order-create"             # your GCP project id
REGION="us-central1"                     # Cloud Run + AR region
DOMAIN="your.custom.domain.com"          # public hostname (A record will point here)
STORE_BASE_URL="https://YOUR_STORE.retail.lightspeed.app/api/2.0"
LS_API_KEY="YOUR_API_KEY"
OUTLET_ID="YOUR-OUTLET-ID"
IAP_USER_EMAIL="user@googleworkspaceaddress.com"  # who should be able to access via IAP
INTERACTIVE="${INTERACTIVE:-true}" 
# If you already created an OAuth client for IAP at the LB (Backend Services) layer, set these:
IAP_CLIENT_ID=""
IAP_CLIENT_SECRET=""

#############################################
# Names (usually fine as-is)
#############################################
AR_HOST="${REGION}-docker.pkg.dev"
REPO="apps"
SVC_API="faire-lite-api"
SVC_UI="faire-lite-ui"
RUN_SA_NAME="run-svc"
RUN_SA="${RUN_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

NEG_UI="ui-neg"
NEG_API="api-neg"
BS_UI="bs-faire-lite-ui"
BS_API="bs-faire-lite-api"
URL_MAP="ls-order-map"
CERT_NAME="ls-order-cert"
PROXY_NAME="ls-order-proxy"
FR_NAME="ls-order-forwarding-rule"
IP_NAME="ls-order-ip"
PATH_MATCHER="api-matcher"

#############################################
# Helpers
#############################################
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok(){ echo -e "\033[1;32m[DONE]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }

require(){ command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; exit 1; }; }

#############################################
# 0) Auth & project (sanity checks)
#############################################
require gcloud

# Ensure you're logged in
ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE_ACCT}" ]]; then
  info "No active gcloud auth; launching login…"
  gcloud auth login --brief
fi

# Ensure the project exists / you have access
if ! gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Project ${PROJECT_ID} not found or access denied."
  exit 1
fi

# Ensure the active project is set
CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "${CURRENT_PROJECT}" != "${PROJECT_ID}" ]]; then
  info "Setting active project to ${PROJECT_ID}"
  gcloud config set project "${PROJECT_ID}" >/dev/null
fi

# Ensure default regions (optional but reduces flags later)
if [[ "$(gcloud config get-value run/region 2>/dev/null || true)" != "${REGION}" ]]; then
  gcloud config set run/region "${REGION}" >/dev/null
fi
if [[ "$(gcloud config get-value compute/region 2>/dev/null || true)" != "${REGION}" ]]; then
  gcloud config set compute/region "${REGION}" >/dev/null
fi

#############################################
# 1) Enable APIs (idempotent / re-run safe)
#############################################
info "Ensuring required services/APIs are enabled…"

REQUIRED_SERVICES=(
  run.googleapis.com
  compute.googleapis.com
  secretmanager.googleapis.com
  iap.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  cloudresourcemanager.googleapis.com   
  iam.googleapis.com                    
)

TO_ENABLE=()
for svc in "${REQUIRED_SERVICES[@]}"; do
  if ! gcloud services list --enabled --format='value(config.name)' \
        --filter="config.name:${svc}" | grep -q "^${svc}$"; then
    TO_ENABLE+=("${svc}")
  fi
done

if ((${#TO_ENABLE[@]})); then
  info "Enabling: ${TO_ENABLE[*]}"
  gcloud services enable "${TO_ENABLE[@]}"
  # Verify after enable
  MISSING=()
  for svc in "${TO_ENABLE[@]}"; do
    if ! gcloud services list --enabled --format='value(config.name)' \
          --filter="config.name:${svc}" | grep -q "^${svc}$"; then
      MISSING+=("${svc}")
    fi
  done
  if ((${#MISSING[@]})); then
    warn "Some services not yet enabled (may still be propagating): ${MISSING[*]}"
  else
    ok "All required services are enabled."
  fi
else
  ok "All required services already enabled."
fi

#############################################
# 2) Artifact Registry repo + build images (idempotent; NO auto rebuilds)
#############################################

# Policy: when images already exist, should we rebuild?
#   never  = skip (default)
#   prompt = ask only if INTERACTIVE=true
#   always = rebuild unconditionally
REBUILD_IMAGES="${REBUILD_IMAGES:-prompt}"
INTERACTIVE="${INTERACTIVE:-true}"

# prompt helper (default "no" when non-interactive)
if ! declare -F prompt_yes_no >/dev/null 2>&1; then
  prompt_yes_no() {
    local msg="${1:-Proceed?}" ans
    if [[ "${INTERACTIVE}" != "true" ]]; then echo "no"; return; fi
    read -r -p "${msg} [y/N]: " ans
    [[ "${ans}" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
  }
fi

info "Ensuring Artifact Registry repo exists: ${REPO}"
if ! gcloud artifacts repositories describe "${REPO}" --location="${REGION}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REPO}" --repository-format=docker --location="${REGION}"
  ok "Created Artifact Registry repo ${REPO} in ${REGION}"
else
  ok "Artifact Registry repo ${REPO} already exists."
fi

# Ensure Cloud Build SA can push to AR (idempotent)
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

HAS_BINDING="$(gcloud artifacts repositories get-iam-policy "${REPO}" --location="${REGION}" \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/artifactregistry.writer AND bindings.members=serviceAccount:${CB_SA}" \
  --format="value(bindings.members)" 2>/dev/null || true)"

if [[ -n "${HAS_BINDING}" ]]; then
  ok "Cloud Build SA already has Artifact Registry writer."
else
  info "Granting Artifact Registry writer to Cloud Build SA ${CB_SA}"
  gcloud artifacts repositories add-iam-policy-binding "${REPO}" --location="${REGION}" \
    --member="serviceAccount:${CB_SA}" --role="roles/artifactregistry.writer" >/dev/null
  ok "Granted AR writer to ${CB_SA}"
fi

# Verify build contexts & Dockerfiles exist
[[ -d "./backend"  && -f "./backend/Dockerfile"  ]] || { echo "Missing ./backend or Dockerfile"; exit 1; }
[[ -d "./frontend" && -f "./frontend/Dockerfile" ]] || { echo "Missing ./frontend or Dockerfile"; exit 1; }

# Check if :latest tag exists in AR
# Section 2 — replace tag_exists + build_if_needed with the below

# Returns 0 if :latest exists for IMAGE (IMAGE name only, no :tag)
tag_exists() {
  local image_no_tag="${1%:*}"
  gcloud artifacts docker tags list "${AR_HOST}/${PROJECT_ID}/${REPO}/${image_no_tag}" \
    --format='value(tag)' 2>/dev/null | grep -qx 'latest'
}

build_image() {
  local ctx="$1" image="$2"
  info "Building & pushing ${image}:latest from ${ctx}…"
  gcloud builds submit "${ctx}" --tag "${AR_HOST}/${PROJECT_ID}/${REPO}/${image}:latest"
  ok "Pushed ${image}:latest"
}

# REBUILD_IMAGES: never | prompt | always   (and set INTERACTIVE=true if you want to be asked)
build_if_needed() {
  local ctx="$1" image="$2"
  local has_latest=false
  if tag_exists "${image}"; then has_latest=true; fi

  case "${REBUILD_IMAGES:-never}" in
    always)
      build_image "${ctx}" "${image}"
      ;;

    prompt)
      if [[ "${has_latest}" == true ]]; then
        # Tag exists — ask about rebuild
        if [[ "$(prompt_yes_no "Rebuild and push ${image}:latest?")" == "yes" ]]; then
          build_image "${ctx}" "${image}"
        else
          ok "Skipped rebuild of ${image}:latest (prompt declined)."
        fi
      else
        # Tag missing — ask about initial build (was previously auto-build)
        if [[ "$(prompt_yes_no "No ${image}:latest found. Build initial image now?")" == "yes" ]]; then
          build_image "${ctx}" "${image}"
        else
          warn "Skipped initial build of ${image}:latest; later deploy may fail."
        fi
      fi
      ;;

    never|*)
      if [[ "${has_latest}" == true ]]; then
        ok "Skipped rebuild of ${image}:latest (policy: never)."
      else
        warn "No ${image}:latest found and policy=never — skipping initial build; deploy may fail."
      fi
      ;;
  esac
}

info "Building & pushing images to Artifact Registry (policy: ${REBUILD_IMAGES})…"
build_if_needed "./backend"  "${SVC_API}"
build_if_needed "./frontend" "${SVC_UI}"

#############################################
# 3) Secrets — sanitize inputs & add only if changed (re-run safe)
#############################################

# Small helpers (CRLF-safe, Windows-friendly)
_hash256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

_trim_spaces() { # trims leading/trailing whitespace
  local s="$1"
  # trim leading
  s="${s#"${s%%[![:space:]]*}"}"
  # trim trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_unquote() { # remove matching outer quotes "like this" or 'like this'
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" ]]; then s="${s:1:${#s}-2}"; fi
  if [[ "$s" == \'*\' && "$s" == *\' ]]; then s="${s:1:${#s}-2}"; fi
  printf '%s' "$s"
}

_sanitize_secret() {
  # strips CR, trailing LF, trims spaces, removes wrapping quotes
  local v="$1"
  # remove carriage returns (CRLF -> LF)
  v="${v//$'\r'/}"
  # drop trailing newlines
  v="${v%$'\n'}"
  v="$(_unquote "$v")"
  v="$(_trim_spaces "$v")"
  printf '%s' "$v"
}

_normalize_base_url() {
  # ensure no trailing slash (optional, but avoids // in clients)
  local u="$1"
  u="${u%/}"
  printf '%s' "$u"
}

# Create secret if missing; add a new version ONLY if sanitized value changed
_ensure_secret_value() {
  local name="$1" raw="$2" sanitized
  sanitized="$(_sanitize_secret "$raw")"
  if [[ "$name" == "LS_BASE_URL" ]]; then
    sanitized="$(_normalize_base_url "$sanitized")"
  fi

  # Create the secret if missing
  if ! gcloud secrets describe "$name" >/dev/null 2>&1; then
    info "Creating secret: $name"
    printf '%s' "$sanitized" | gcloud secrets create "$name" \
      --replication-policy="automatic" --data-file=- >/dev/null
    ok "Secret $name created."
    return 0
  fi

  # --- get existing (if any), then SANITIZE it the same way ---
  existing_raw="$(
    gcloud secrets versions access latest --secret="$name" 2>/dev/null || true
  )"
  existing_sanitized="$(_sanitize_secret "$existing_raw")"
  if [[ "$name" == "LS_BASE_URL" ]]; then
    existing_sanitized="$(_normalize_base_url "$existing_sanitized")"
  fi

  # Hash both sanitized values
  hash_new="$(printf '%s' "$sanitized" | _hash256)"
  hash_old="$(printf '%s' "$existing_sanitized" | _hash256)"

  # Optional debug without leaking secrets
  if [[ "${DEBUG_SECRETS:-false}" == "true" ]]; then
    echo "[DEBUG] $name new len=$(printf '%s' "$sanitized" | wc -c) hash=$hash_new"
    echo "[DEBUG] $name old len=$(printf '%s' "$existing_sanitized" | wc -c) hash=$hash_old"
  fi

  if [[ "$hash_new" == "$hash_old" ]]; then
    ok "Secret $name already up-to-date; no new version added."
  else
    info "Adding new version to secret: $name"
    printf '%s' "$sanitized" | gcloud secrets versions add "$name" --data-file=- >/dev/null
    ok "Secret $name updated."
  fi
}

# Use your env vars as before (STORE_BASE_URL, LS_API_KEY, OUTLET_ID)
_ensure_secret_value "LS_BASE_URL" "${STORE_BASE_URL}"
_ensure_secret_value "LS_API_KEY"  "${LS_API_KEY}"
_ensure_secret_value "OUTLET_ID"   "${OUTLET_ID}"

#############################################
# 4) Runtime Service Account & Secret access (idempotent)
#############################################
info "Ensuring Cloud Run runtime service account: ${RUN_SA}"

# Create SA if missing (then wait for propagation)
if ! gcloud iam service-accounts describe "${RUN_SA}" --format="value(email)" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${RUN_SA_NAME}" --display-name="Cloud Run runtime SA"
  info "Waiting for service account to propagate…"
  for i in {1..30}; do
    gcloud iam service-accounts describe "${RUN_SA}" --format="value(email)" >/dev/null 2>&1 && break
    sleep 2
  done
fi

# Final sanity check (fail early if still not visible)
gcloud iam service-accounts describe "${RUN_SA}" --format="value(email)" >/dev/null

# Grant Secret Manager access only if missing (exact match), with small retry/backoff
grant_secret_binding() {
  local secret_name="$1"
  local secret_res="projects/${PROJECT_ID}/secrets/${secret_name}"

  # Check current policy: exact role + member
  local has_binding
  has_binding="$(
    gcloud secrets get-iam-policy "${secret_res}" --project="${PROJECT_ID}" \
      --flatten="bindings[].members" \
      --filter="bindings.role=roles/secretmanager.secretAccessor AND bindings.members=serviceAccount:${RUN_SA}" \
      --format="value(bindings.members)" 2>/dev/null || true
  )"

  if [[ -n "${has_binding}" ]]; then
    ok "Secret ${secret_name}: accessor already includes serviceAccount:${RUN_SA}"
    return 0
  fi

  # Add binding with retries for IAM propagation quirks
  for attempt in {1..5}; do
    info "Granting Secret Manager access for ${RUN_SA} on ${secret_name} (attempt ${attempt})"
    if gcloud secrets add-iam-policy-binding "${secret_res}" --project="${PROJECT_ID}" \
         --member="serviceAccount:${RUN_SA}" \
         --role="roles/secretmanager.secretAccessor" >/dev/null 2>&1; then
      # Post-verify
      has_binding="$(
        gcloud secrets get-iam-policy "${secret_res}" --project="${PROJECT_ID}" \
          --flatten="bindings[].members" \
          --filter="bindings.role=roles/secretmanager.secretAccessor AND bindings.members=serviceAccount:${RUN_SA}" \
          --format="value(bindings.members)" 2>/dev/null || true
      )"
      if [[ -n "${has_binding}" ]]; then
        ok "Secret ${secret_name}: binding present."
        return 0
      fi
    fi
    sleep $((2**attempt))
  done

  warn "Secret ${secret_name}: failed to add binding after retries."
  return 1
}

for s in LS_BASE_URL LS_API_KEY OUTLET_ID; do
  grant_secret_binding "${s}"
done

#############################################
# 5) Deploy Cloud Run (idempotent / interactive)
#############################################

# Honor existing INTERACTIVE; default to false
INTERACTIVE="${INTERACTIVE:-true}"

# Only define prompt if not defined earlier
if ! declare -F prompt_yes_no >/dev/null 2>&1; then
  prompt_yes_no() {
    local msg="${1:-Proceed?}"; local ans
    if [[ "${INTERACTIVE}" != "true" ]]; then echo "yes"; return; fi
    read -r -p "${msg} [y/N]: " ans
    [[ "${ans}" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
  }
fi

# Auth mode for Cloud Run behind LB+IAP
# false = allow unauth (LB/IAP gates)
# true  = require Cloud Run IAM (needs IAP SA invoker)
REQUIRE_AUTH="${REQUIRE_AUTH:-false}"

# Tag existence helper (defined earlier in #2; define here if missing)
if ! declare -F tag_exists >/dev/null 2>&1; then
  tag_exists() {
    # Accept "name" or "name:tag"; always check the repo path without a tag
    local image_no_tag="${1%:*}"
    gcloud artifacts docker tags list "${AR_HOST}/${PROJECT_ID}/${REPO}/${image_no_tag}" \
      --format='value(tag)' 2>/dev/null | grep -qx 'latest'
  }
fi

_current_image() {
  local svc="$1"
  gcloud run services describe "${svc}" --region "${REGION}" \
    --format="value(spec.template.spec.containers[0].image)" 2>/dev/null || true
}

_current_sa() {
  local svc="$1"
  gcloud run services describe "${svc}" --region "${REGION}" \
    --format="value(spec.template.spec.serviceAccountName)" 2>/dev/null || true
}

deploy_run() {
  local svc="$1" image="$2" port="$3"; shift 3

  local AUTH_FLAG="--allow-unauthenticated"
  [[ "${REQUIRE_AUTH}" == "true" ]] && AUTH_FLAG="--no-allow-unauthenticated"

  local exists=0
  gcloud run services describe "${svc}" --region "${REGION}" >/dev/null 2>&1 || exists=1

  local current_img="$(_current_image "${svc}")"
  local current_sa="$(_current_sa "${svc}")"

  # If service exists, show current state and optionally skip
  if (( exists == 0 )); then
    info "Updating Cloud Run service: ${svc}"
    info "Current image: ${current_img:-<none>}  →  Target: ${image}"
    info "Current SA:    ${current_sa:-<none>}  →  Target: ${RUN_SA}"
    if [[ "${INTERACTIVE}" == "true" && "${current_img}" == "${image}" && "${current_sa}" == "${RUN_SA}" ]]; then
      if [[ "$(prompt_yes_no "No image/SA change detected for ${svc}. Redeploy anyway?")" != "yes" ]]; then
        ok "Skipped redeploy of ${svc} (no changes)."
        return 0
      fi
    fi
  else
    info "Creating Cloud Run service: ${svc}"
  fi

  # Sanity: ensure image tag exists in AR (avoid deploy loop errors)
  local art_image_path="${AR_HOST}/${PROJECT_ID}/${REPO}/$(basename "${image}")"
  if ! tag_exists "$(basename "${image}")"; then
    warn "Artifact Registry does not show tag 'latest' for $(basename "${image}")."
    if [[ "$(prompt_yes_no "Proceed with deploy anyway? (may fail if image not pushed)")" != "yes" ]]; then
      warn "Deployment of ${svc} canceled by user (image not present)."
      return 1
    fi
  fi

  # One deploy attempt; if it fails, offer options (retry / toggle auth / skip)
  local errlog; errlog="$(mktemp)"
  local attempt_auth="${AUTH_FLAG}"

  while :; do
    if gcloud run deploy "${svc}" \
         --image "${image}" \
         --region "${REGION}" \
         --platform managed \
         --ingress internal-and-cloud-load-balancing \
         ${attempt_auth} \
         --service-account "${RUN_SA}" \
         --port "${port}" \
         "$@" 2>"${errlog}"; then
      ok "Deployed ${svc}"
      rm -f "${errlog}"
      return 0
    fi

    # On error:
    warn "Deploy ${svc} failed."
    tail -n 20 "${errlog}" | sed 's/^/  /'
    if [[ "${INTERACTIVE}" != "true" ]]; then
      echo "ERROR: Failed to deploy ${svc}. (Run with INTERACTIVE=true for guided recovery.)" >&2
      rm -f "${errlog}"
      return 1
    fi

    echo
    echo "Choose: [R]etry  [T]oggle auth flag  [S]kip"
    read -r -p "Action for ${svc}: " choice
    case "${choice,,}" in
      r|retry)
        info "Retrying deploy of ${svc}…"
        ;;
      t|toggle)
        if [[ "${attempt_auth}" == "--allow-unauthenticated" ]]; then
          attempt_auth="--no-allow-unauthenticated"
          info "Auth flag toggled → --no-allow-unauthenticated"
        else
          attempt_auth="--allow-unauthenticated"
          info "Auth flag toggled → --allow-unauthenticated"
        fi
        ;;
      s|skip)
        warn "Skipping deploy of ${svc} on user request."
        rm -f "${errlog}"
        return 1
        ;;
      *)
        warn "Unrecognized choice; retrying."
        ;;
    esac
  done
}

# API (secrets wired)
deploy_run "${SVC_API}" \
  "${AR_HOST}/${PROJECT_ID}/${REPO}/${SVC_API}:latest" \
  8081 \
  --update-secrets "LS_BASE_URL=LS_BASE_URL:latest,LS_API_KEY=LS_API_KEY:latest,OUTLET_ID=OUTLET_ID:latest"

# UI (env var wired)
deploy_run "${SVC_UI}" \
  "${AR_HOST}/${PROJECT_ID}/${REPO}/${SVC_UI}:latest" \
  8080 \
  --set-env-vars "VITE_API_URL=https://${DOMAIN}"

#############################################
# 6) Serverless NEGs (need existing Cloud Run)
#    - Re-run safe
#    - Interactive "update or keep" if bound to a different service
#############################################

# Set to "true" to prompt; "false" to always keep existing NEGs
INTERACTIVE="${INTERACTIVE:-true}"
# INTERACTIVE="${INTERACTIVE:-false}"

prompt_yes_no() {
  local msg="${1:-Proceed?}"; local default_no="${2:-true}"; local ans
  if [[ "${INTERACTIVE}" != "true" ]]; then
    echo "no"  # auto "no" in non-interactive mode
    return
  fi
  read -r -p "${msg} [y/N]: " ans
  if [[ "${ans}" =~ ^[Yy]$ ]]; then echo "yes"; else echo "no"; fi
}

ensure_serverless_neg() {
  local neg="$1" target_service="$2" backend_service="$3"

  # Does NEG exist?
  if ! gcloud compute network-endpoint-groups describe "${neg}" --region="${REGION}" >/dev/null 2>&1; then
    info "Creating serverless NEG: ${neg} -> Cloud Run service ${target_service}"
    gcloud compute network-endpoint-groups create "${neg}" \
      --region="${REGION}" \
      --network-endpoint-type=serverless \
      --cloud-run-service="${target_service}"
    ok "Created NEG ${neg}"
    return 0
  fi

  # It exists — check what it's pointing to now
  local current_service
  current_service="$(gcloud compute network-endpoint-groups describe "${neg}" --region="${REGION}" \
                    --format="value(cloudRun.service)" 2>/dev/null || true)"
  current_service="${current_service:-unknown}"

  if [[ "${current_service}" == "${target_service}" ]]; then
    ok "NEG ${neg} already targets ${target_service}."
    return 0
  fi

  warn "NEG ${neg} targets '${current_service}', not '${target_service}'."

  # Ask user if they want to update (recreate) the NEG
  if [[ "$(prompt_yes_no "Update ${neg} to target ${target_service} (will recreate NEG and detach from ${backend_service} if attached)?" )" == "yes" ]]; then
    info "Detaching ${neg} from backend service ${backend_service} (if attached)…"
    gcloud compute backend-services remove-backend "${backend_service}" --global \
      --network-endpoint-group="${neg}" \
      --network-endpoint-group-region="${REGION}" >/dev/null 2>&1 || true

    info "Deleting NEG ${neg}…"
    gcloud compute network-endpoint-groups delete "${neg}" --region="${REGION}" --quiet

    info "Recreating NEG ${neg} -> Cloud Run service ${target_service}"
    gcloud compute network-endpoint-groups create "${neg}" \
      --region="${REGION}" \
      --network-endpoint-type=serverless \
      --cloud-run-service="${target_service}"
    ok "NEG ${neg} now points to ${target_service}."
  else
    ok "Keeping existing NEG ${neg} -> ${current_service}."
  fi
}

info "Ensuring serverless NEGs…"
ensure_serverless_neg "${NEG_UI}"  "${SVC_UI}"  "${BS_UI}"
ensure_serverless_neg "${NEG_API}" "${SVC_API}" "${BS_API}"

#############################################
# 7) Backend services + attach NEGs (idempotent / interactive)
#############################################

# If you didn't define INTERACTIVE/prompt_yes_no earlier, this provides safe defaults.
INTERACTIVE="${INTERACTIVE:-true}"
# INTERACTIVE="${INTERACTIVE:-false}"
prompt_yes_no() {
  local msg="${1:-Proceed?}"; local ans
  if [[ "${INTERACTIVE}" != "true" ]]; then echo "yes"; return; fi
  read -r -p "${msg} [y/N]: " ans
  [[ "${ans}" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
}

ensure_backend_service() {
  local bs="$1"
  if gcloud compute backend-services describe "${bs}" --global >/dev/null 2>&1; then
    ok "Backend service ${bs} exists."
  else
    info "Creating backend service ${bs} (EXTERNAL_MANAGED)…"
    gcloud compute backend-services create "${bs}" \
      --global --load-balancing-scheme=EXTERNAL_MANAGED
    ok "Created ${bs}."
  fi
}

# --- REPLACE your list_attached_negs with this ---
list_attached_negs() {
  # prints: "<negName> <region>" per line
  local bs="$1"
  local g
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    g="${g//$'\r'/}"  # strip CR from Windows CRLF
    # NEG name = last path segment
    local neg="${g##*/}"
    # Region between /regions/ and /networkEndpointGroups/
    local region
    region="$(sed -n 's#.*/regions/\([^/]*\)/networkEndpointGroups/.*#\1#p' <<<"$g")"
    printf '%s %s\n' "$neg" "$region"
  done < <(gcloud compute backend-services describe "${bs}" --global \
           --format='value(backends[].group)' 2>/dev/null)
}

attach_neg_if_missing() {
  local bs="$1" neg="$2" region="$3"

  # Is the expected NEG already attached?
  if list_attached_negs "${bs}" | awk '{print $1}' | grep -qx "${neg}"; then
    ok "Backend ${bs} already has NEG ${neg} attached."
  else
    if [[ "$(prompt_yes_no "Attach NEG ${neg} (region ${region}) to backend ${bs}?")" == "yes" ]]; then
      info "Attaching ${neg} to ${bs}…"
      gcloud compute backend-services add-backend "${bs}" --global \
        --network-endpoint-group="${neg}" \
        --network-endpoint-group-region="${region}"
      ok "Attached ${neg} to ${bs}."
    else
      warn "Skipped attaching ${neg} to ${bs}."
    fi
  fi
}

# --- REPLACE your maybe_remove_stale_negs with this ---
maybe_remove_stale_negs() {
  local bs="$1" expected_neg="$2"
  expected_neg="${expected_neg//$'\r'/}"   # normalize (Windows CR)

  local stale=()
  while read -r neg rgn; do
    [[ -z "$neg" ]] && continue
    neg="${neg//$'\r'/}"
    rgn="${rgn//$'\r'/}"
    if [[ "${neg}" != "${expected_neg}" ]]; then
      stale+=("${neg}:${rgn}")
    fi
  done < <(list_attached_negs "${bs}")

  (( ${#stale[@]} == 0 )) && return 0

  warn "Backend ${bs} has additional NEGs attached: ${stale[*]}"
  if [[ "$(prompt_yes_no "Remove NEGs not equal to ${expected_neg} from ${bs}?")" == "yes" ]]; then
    for pair in "${stale[@]}"; do
      local neg="${pair%%:*}"
      local rgn="${pair##*:}"
      info "Detaching stale NEG ${neg} (region ${rgn}) from ${bs}…"
      gcloud compute backend-services remove-backend "${bs}" --global \
        --network-endpoint-group="${neg}" \
        --network-endpoint-group-region="${rgn}" || true
    done
    ok "Stale NEGs removed from ${bs}."
  else
    ok "Keeping existing extra NEGs on ${bs}."
  fi
}

info "Ensuring backend services exist…"
ensure_backend_service "${BS_UI}"
ensure_backend_service "${BS_API}"

info "Ensuring expected NEGs are attached…"
attach_neg_if_missing "${BS_UI}"  "${NEG_UI}"  "${REGION}"
attach_neg_if_missing "${BS_API}" "${NEG_API}" "${REGION}"

# Optional cleanup of unexpected NEGs (interactive)
maybe_remove_stale_negs "${BS_UI}"  "${NEG_UI}"
maybe_remove_stale_negs "${BS_API}" "${NEG_API}"

#############################################
# 8) Enable IAP on LB backend services (re-run safe; no OAuth client)
#############################################

# Prompt helper (only define if missing; default "no" when non-interactive)
if ! declare -F prompt_yes_no >/dev/null 2>&1; then
  INTERACTIVE="${INTERACTIVE:-true}"
  prompt_yes_no(){ local m="${1:-Proceed?}" a; [[ "$INTERACTIVE" != "true" ]] && { echo no; return; }
                   read -r -p "$m [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]] && echo yes || echo no; }
fi

ensure_iap_enabled_bs() {
  local bs="$1"
  local enabled
  enabled="$(gcloud compute backend-services describe "$bs" --global \
              --format='value(iap.enabled)' 2>/dev/null || true)"
  if [[ "$enabled" == "True" ]]; then
    ok "IAP already enabled on ${bs}"
    return 0
  fi
  if [[ "$(prompt_yes_no "Enable IAP on backend service ${bs}?")" != "yes" ]]; then
    warn "Skipping IAP enable on ${bs}."
    return 0
  fi
  gcloud compute backend-services update "$bs" --global --iap=enabled
  # small poll for visibility
  for i in {1..10}; do
    enabled="$(gcloud compute backend-services describe "$bs" --global --format='value(iap.enabled)' 2>/dev/null || true)"
    [[ "$enabled" == "True" ]] && { ok "IAP enabled on ${bs}"; return 0; }
    sleep 2
  done
  warn "IAP enable on ${bs} not visible yet; continuing."
}

# IAP service agent (lets IAP call Cloud Run)
# Returns the IAP service agent email; creates it only if missing.
# Returns the IAP service agent email; creates only if missing.
# Returns the IAP service agent email; creates only if missing. Quiet + cached.
# IAP service agent (lets IAP call Cloud Run)
# Returns the IAP service agent email; creates only if missing. Quiet + cached.
ensure_iap_service_agent() {
  if [[ -n "${IAP_SA_CACHED:-}" ]]; then printf '%s' "$IAP_SA_CACHED"; return; fi

  local pn sa created=0
  pn="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
  sa="service-${pn}@gcp-sa-iap.iam.gserviceaccount.com"

  # already exists?
  if gcloud iam service-accounts describe "$sa" --project="$PROJECT_ID" >/dev/null 2>&1; then
    IAP_SA_CACHED="$sa"; printf '%s' "$sa"; return
  fi

  # create ONLY if still missing
  if ! gcloud iam service-accounts describe "$sa" --project="$PROJECT_ID" >/dev/null 2>&1; then
    >&2 echo "[INFO] Creating IAP service agent (services identity)..."
    gcloud beta services identity create --service=iap.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true
    created=1
  fi

  # wait only if we tried to create
  if (( created )); then
    >&2 echo "[INFO] Waiting for IAP service agent to propagate..."
    for i in {1..30}; do
      if gcloud iam service-accounts describe "$sa" --project="$PROJECT_ID" >/dev/null 2>&1; then
        IAP_SA_CACHED="$sa"; printf '%s' "$sa"; return
      fi
      sleep 2
    done
    >&2 echo "[WARN] IAP service agent not visible yet; continuing."
  fi

  IAP_SA_CACHED="$sa"
  printf '%s' "$sa"
}

# Run.invoker on Cloud Run for IAP SA
ensure_run_invoker_binding() {
  local svc="$1" member="$2"
  if gcloud run services get-iam-policy "${svc}" --region "${REGION}" --project "${PROJECT_ID}" \
       --format="value(bindings.members)" \
       --filter="bindings.role=roles/run.invoker" 2>/dev/null \
     | grep -qx "serviceAccount:${member}"; then
    ok "Cloud Run ${svc}: roles/run.invoker already includes serviceAccount:${member}"
  else
    info "Granting roles/run.invoker on ${svc} to serviceAccount:${member}"
    gcloud run services add-iam-policy-binding "${svc}" \
      --region "${REGION}" --project "${PROJECT_ID}" \
      --member="serviceAccount:${member}" \
      --role="roles/run.invoker" >/dev/null
    ok "Added invoker on ${svc} to ${member}"
  fi
}

# IAP viewer binding on backend services (supports user:, group:, serviceAccount:, domain:)
ensure_iap_accessor() {
  local bs="$1" principal="$2"

  # Check for exact role+member with flatten+filter (no hanging)
  local has_binding
  has_binding="$(
    gcloud iap web get-iam-policy \
      --resource-type=backend-services \
      --service="${bs}" \
      --project="${PROJECT_ID}" \
      --flatten="bindings[].members" \
      --filter="bindings.role=roles/iap.httpsResourceAccessor AND bindings.members=${principal}" \
      --format="value(bindings.members)" 2>/dev/null || true
  )"

  if [[ -n "${has_binding}" ]]; then
    ok "IAP policy on ${bs}: already includes ${principal}"
    return 0
  fi

  # Ask before granting (so INTERACTIVE=true actually prompts here)
  if [[ "$(prompt_yes_no "Grant IAP access (roles/iap.httpsResourceAccessor) on ${bs} to ${principal}?")" != "yes" ]]; then
    warn "Skipped granting IAP access on ${bs} to ${principal}."
    return 0
  fi

  info "Granting IAP access (roles/iap.httpsResourceAccessor) on ${bs} to ${principal}"
  gcloud iap web add-iam-policy-binding \
    --resource-type=backend-services \
    --service="${bs}" \
    --member="${principal}" \
    --role="roles/iap.httpsResourceAccessor" \
    --project="${PROJECT_ID}" >/dev/null

  ok "Added IAP accessor on ${bs} to ${principal}"
}

if [[ "${IAP_ANY}" != "true" ]]; then
  warn "IAP not enabled on ${BS_UI}/${BS_API}; skipping IAP service-agent invoker bindings."
else
  IAP_SA="$(ensure_iap_service_agent)"
  ensure_run_invoker_binding "${SVC_UI}"  "${IAP_SA}"
  ensure_run_invoker_binding "${SVC_API}" "${IAP_SA}"
fi

# Accept: IAP_PRINCIPALS="alice@x.com,bob@x.com group:team@x.com"
IAP_PRINCIPALS="${IAP_PRINCIPALS:-${IAP_USER_EMAIL:-}}"

# 8.1 Enable IAP on the LB backend services
ensure_iap_enabled_bs "${BS_UI}"
ensure_iap_enabled_bs "${BS_API}"

# 8.2 Let IAP call your Cloud Run services
IAP_SA="$(ensure_iap_service_agent)"
ensure_run_invoker_binding "${SVC_UI}"  "${IAP_SA}"
ensure_run_invoker_binding "${SVC_API}" "${IAP_SA}"

# 8.3 Grant viewer access to your users/groups
IAP_PRINCIPALS="${IAP_PRINCIPALS:-${IAP_USER_EMAIL:-}}"
normalize_principal(){ local p="$1"; [[ "$p" =~ ^(user|group|serviceAccount|domain): ]] && echo "$p" || echo "user:$p"; }
if [[ -n "${IAP_PRINCIPALS//[[:space:]]/}" ]]; then
  IFS=',; ' read -r -a _p <<< "$IAP_PRINCIPALS"
  for raw in "${_p[@]}"; do
    [[ -z "$raw" ]] && continue
    ensure_iap_accessor "${BS_UI}"  "$(normalize_principal "$raw")"
    ensure_iap_accessor "${BS_API}" "$(normalize_principal "$raw")"
  done
else
  warn "No IAP principals provided (set IAP_PRINCIPALS or IAP_USER_EMAIL) — skipping IAP viewer binding."
fi

# 8.4 Verify
ui_on="$(gcloud compute backend-services describe "${BS_UI}"  --global --format='value(iap.enabled)')"
api_on="$(gcloud compute backend-services describe "${BS_API}" --global --format='value(iap.enabled)')"
ok "IAP status — ${BS_UI}: ${ui_on:-?},  ${BS_API}: ${api_on:-?}"

#############################################
# 9) IAP bindings (allow IAP to call Run, grant user access) — idempotent
#############################################
info "Binding IAP → Cloud Run invoker & granting user access (re-run safe)…"

iap_enabled() {
  local bs="$1"
  [[ "$(gcloud compute backend-services describe "${bs}" --global --project="${PROJECT_ID}" \
       --format='value(iap.enabled)' 2>/dev/null)" == "True" ]]
}

IAP_ANY=false
iap_enabled "${BS_UI}"  && IAP_ANY=true
iap_enabled "${BS_API}" && IAP_ANY=true

normalize_principal() {
  local p="$1"
  [[ "$p" =~ ^(user|group|serviceAccount|domain): ]] && echo "$p" || echo "user:$p"
}

# proceed only if we have at least one non-whitespace char
if [[ -n "${IAP_PRINCIPALS//[[:space:]]/}" ]]; then
  # split on commas, semicolons, or whitespace
  IFS=',; ' read -r -a _principals <<< "$IAP_PRINCIPALS"
  for raw in "${_principals[@]}"; do
    [[ -z "$raw" ]] && continue
    p="$(normalize_principal "$raw")"
    ensure_iap_accessor "${BS_UI}"  "$p"
    ensure_iap_accessor "${BS_API}" "$p"
  done
else
  warn "No IAP principals provided (set IAP_PRINCIPALS or IAP_USER_EMAIL) — skipping IAP viewer binding."
fi

#############################################
# 10) LB: IP, URL map, cert, proxy, forwarding rule (idempotent)
#############################################

# Only define prompt if not already defined; default to "no" when non-interactive
if ! declare -F prompt_yes_no >/dev/null 2>&1; then
  INTERACTIVE="${INTERACTIVE:-true}"
  prompt_yes_no() {
    local msg="${1:-Proceed?}" ans
    if [[ "${INTERACTIVE}" != "true" ]]; then echo "no"; return; fi
    read -r -p "${msg} [y/N]: " ans
    [[ "${ans}" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
  }
fi

## 10.1 Global IP
info "Allocating global IP (if needed)…"
if ! gcloud compute addresses describe "${IP_NAME}" --global >/dev/null 2>&1; then
  gcloud compute addresses create "${IP_NAME}" --global
fi
LB_IP="$(gcloud compute addresses describe "${IP_NAME}" --global --format='value(address)')"
ok "LB IP: ${LB_IP}"

## 10.2 URL map (exists + default service)
info "Ensuring URL map ${URL_MAP}…"
if ! gcloud compute url-maps describe "${URL_MAP}" >/dev/null 2>&1; then
  gcloud compute url-maps create "${URL_MAP}" --default-service="${BS_UI}"
  ok "Created URL map ${URL_MAP} with default ${BS_UI}"
else
  current_default="$(gcloud compute url-maps describe "${URL_MAP}" --format='value(defaultService.basename())')"
  if [[ "${current_default}" != "${BS_UI}" ]]; then
    info "Setting URL map ${URL_MAP} default service -> ${BS_UI} (was ${current_default})"
    gcloud compute url-maps set-default-service "${URL_MAP}" --default-service="${BS_UI}"
    ok "Updated default service"
  else
    ok "URL map default service already ${BS_UI}"
  fi
fi

# 10.2b Path-matcher for this host: ensure /api/* -> BS_API
pm_exists=""
if gcloud compute url-maps describe "${URL_MAP}" \
     --format='value(pathMatchers[].name)' 2>/dev/null \
  | tr -d '\r' | tr '[:space:]' '\n' | grep -Fxq "${PATH_MATCHER}"; then
  pm_exists="yes"
fi

if [[ -z "${pm_exists}" ]]; then
  info "Adding path matcher ${PATH_MATCHER} (host ${DOMAIN}, /api/* -> ${BS_API})"
  gcloud compute url-maps add-path-matcher "${URL_MAP}" \
    --path-matcher-name="${PATH_MATCHER}" \
    --default-service="${BS_UI}" \
    --new-hosts="${DOMAIN}" \
    --backend-service-path-rules="/api/*=${BS_API}"
  ok "Added path matcher ${PATH_MATCHER}"
else
  api_rule_ok="$(
    gcloud compute url-maps describe "${URL_MAP}" \
      --format='table(pathMatchers[].name, pathMatchers[].pathRules[].paths, pathMatchers[].pathRules[].service.basename())' 2>/dev/null \
    | tr -d '\r' \
    | awk -v m="${PATH_MATCHER}" -v api="${BS_API}" '$1==m && $2=="/api/*" && $3==api {print "ok"; exit}'
  )"
  if [[ "${api_rule_ok}" == "ok" ]]; then
    ok "Path matcher ${PATH_MATCHER} already routes /api/* -> ${BS_API}"
  else
    warn "Path matcher ${PATH_MATCHER} exists but /api/* may not route to ${BS_API}."
    if [[ "$(prompt_yes_no "Create a new path matcher ${PATH_MATCHER}-v2 and move host ${DOMAIN} to it?")" == "yes" ]]; then
      gcloud compute url-maps add-path-matcher "${URL_MAP}" \
        --path-matcher-name="${PATH_MATCHER}-v2" \
        --default-service="${BS_UI}" \
        --existing-host="${DOMAIN}" \
        --backend-service-path-rules="/api/*=${BS_API}"
      ok "Migrated host ${DOMAIN} to ${PATH_MATCHER}-v2 with /api/* -> ${BS_API}"
    else
      info "Keeping existing path matcher configuration."
    fi
  fi
fi

## 10.3 Managed SSL certificate
info "Ensuring managed SSL certificate ${CERT_NAME} for ${DOMAIN}…"
if ! gcloud compute ssl-certificates describe "${CERT_NAME}" >/dev/null 2>&1; then
  gcloud compute ssl-certificates create "${CERT_NAME}" --domains="${DOMAIN}"
  ok "Created managed cert ${CERT_NAME} (will become ACTIVE after DNS resolves)"
else
  cert_domains="$(gcloud compute ssl-certificates describe "${CERT_NAME}" --format='csv[no-heading](managed.domains)' 2>/dev/null || true)"
  if [[ "${cert_domains}" != *"${DOMAIN}"* ]]; then
    warn "Cert ${CERT_NAME} does not include ${DOMAIN} (has: ${cert_domains:-none})."
    if [[ "$(prompt_yes_no "Recreate cert ${CERT_NAME} for ${DOMAIN}? (will delete & create)")" == "yes" ]]; then
      gcloud compute ssl-certificates delete "${CERT_NAME}" --quiet
      gcloud compute ssl-certificates create "${CERT_NAME}" --domains="${DOMAIN}"
      ok "Recreated cert ${CERT_NAME} for ${DOMAIN}"
    else
      info "Keeping existing certificate."
    fi
  else
    status="$(gcloud compute ssl-certificates describe "${CERT_NAME}" --format='value(managed.status)' 2>/dev/null || true)"
    ok "Cert ${CERT_NAME} includes ${DOMAIN} (status: ${status:-unknown})"
  fi
fi

## 10.4 HTTPS proxy (ensure it points to our URL map + cert)
info "Ensuring HTTPS proxy ${PROXY_NAME}…"
if ! gcloud compute target-https-proxies describe "${PROXY_NAME}" >/dev/null 2>&1; then
  gcloud compute target-https-proxies create "${PROXY_NAME}" \
    --url-map="${URL_MAP}" --ssl-certificates="${CERT_NAME}"
  ok "Created HTTPS proxy ${PROXY_NAME}"
else
  current_map="$(gcloud compute target-https-proxies describe "${PROXY_NAME}" --format='value(urlMap.basename())')"
  if [[ "${current_map}" != "${URL_MAP}" ]]; then
    info "Updating proxy ${PROXY_NAME} url-map -> ${URL_MAP} (was ${current_map})"
    gcloud compute target-https-proxies update "${PROXY_NAME}" --url-map="${URL_MAP}"
  fi
  current_cert="$(gcloud compute target-https-proxies describe "${PROXY_NAME}" --format='value(sslCertificates.basename())')"
  if [[ "${current_cert}" != "${CERT_NAME}" ]]; then
    info "Updating proxy ${PROXY_NAME} cert -> ${CERT_NAME} (was ${current_cert})"
    gcloud compute target-https-proxies update "${PROXY_NAME}" --ssl-certificates="${CERT_NAME}"
  fi
  ok "HTTPS proxy ${PROXY_NAME} is set"
fi

## 10.5 Forwarding rule (ensure it targets our proxy)
info "Ensuring global forwarding rule ${FR_NAME}…"
if ! gcloud compute forwarding-rules describe "${FR_NAME}" --global >/dev/null 2>&1; then
  gcloud compute forwarding-rules create "${FR_NAME}" \
    --address="${IP_NAME}" --global --target-https-proxy="${PROXY_NAME}" --ports=443
  ok "Created forwarding rule ${FR_NAME}"
else
  current_target="$(gcloud compute forwarding-rules describe "${FR_NAME}" --global --format='value(target.basename())')"
  if [[ "${current_target}" != "${PROXY_NAME}" ]]; then
    info "Updating forwarding rule ${FR_NAME} target -> ${PROXY_NAME} (was ${current_target})"
    gcloud compute forwarding-rules set-target "${FR_NAME}" --global --target-https-proxy="${PROXY_NAME}"
  fi
  ok "Forwarding rule ${FR_NAME} is set to ${PROXY_NAME}"
fi

#############################################
# 11) DNS check & reminder
#############################################
echo

# Prefer dig; fallback to nslookup
dns_has_dig=false
if command -v dig >/dev/null 2>&1; then dns_has_dig=true; fi

resolve_a() {
  local host="$1" resolver="$2"
  if $dns_has_dig; then
    dig +time=2 +tries=1 +short A "${host}" @"${resolver}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
  else
    # best-effort nslookup parser
    nslookup -type=A "${host}" "${resolver}" 2>/dev/null \
      | awk 'BEGIN{ans=0} /^Name:/ {ans=1; next} ans && /^Address: / {print $2}'
  fi
}

resolve_cname() {
  local host="$1" resolver="$2"
  if $dns_has_dig; then
    dig +time=2 +tries=1 +short CNAME "${host}" @"${resolver}" 2>/dev/null | sed 's/\.$//' || true
  else
    nslookup -type=CNAME "${host}" "${resolver}" 2>/dev/null \
      | awk -v h="${host}." '$0 ~ ("canonical name =") { print $NF }' | sed 's/\.$//' || true
  fi
}

find_zone_and_ns() {
  local host="$1" zone="$1" nslist=""
  while :; do
    if $dns_has_dig; then
      nslist="$(dig +time=2 +tries=1 +short NS "${zone}" 2>/dev/null || true)"
    else
      nslist="$(nslookup -type=NS "${zone}" 2>/dev/null | awk '/nameserver =/ {print $4}' || true)"
    fi
    if [[ -n "${nslist}" ]]; then
      echo "${zone}"
      echo "${nslist}"
      return 0
    fi
    # strip leftmost label; stop at TLD
    zone="${zone#*.}"
    [[ "${zone}" != *.* ]] && break
  done
  echo "" ; echo ""
}

guess_dns_provider() {
  # Heuristic from nameserver hostnames
  local nslist="$1" lower
  lower="$(tr '[:upper:]' '[:lower:]' <<< "${nslist}")"
  if   grep -q 'ns.cloudflare.com' <<< "${lower}"; then echo "Cloudflare"
  elif grep -q 'awsdns'            <<< "${lower}"; then echo "Amazon Route 53"
  elif grep -q 'googledomains.com' <<< "${lower}"; then echo "Google Cloud DNS / Google Domains"
  elif grep -q 'domaincontrol.com' <<< "${lower}"; then echo "GoDaddy"
  elif grep -q 'registrar-servers.com' <<< "${lower}"; then echo "Namecheap"
  elif grep -q 'dnsmadeeasy.com'   <<< "${lower}"; then echo "DNS Made Easy"
  elif grep -q 'azure-dns'         <<< "${lower}"; then echo "Azure DNS"
  elif grep -q 'ultradns'          <<< "${lower}"; then echo "Neustar/UltraDNS"
  elif grep -q 'digitalocean.com'  <<< "${lower}"; then echo "DigitalOcean"
  else echo "Unknown/Other"
  fi
}

info "Checking DNS resolution for ${DOMAIN} (expected A ➜ ${LB_IP})…"

RESOLVERS=("8.8.8.8" "1.1.1.1" "9.9.9.9" "208.67.222.222")
match_count=0
total=${#RESOLVERS[@]}

for r in "${RESOLVERS[@]}"; do
  a_recs="$(resolve_a "${DOMAIN}" "${r}" | xargs)"
  cname_rec="$(resolve_cname "${DOMAIN}" "${r}" | xargs)"
  if [[ -n "${a_recs}" ]]; then
    if grep -qw "${LB_IP}" <<< "${a_recs}"; then
      ok "Resolver ${r}: A ${DOMAIN} ➜ ${a_recs} (✓ matches ${LB_IP})"
      ((match_count++))
    else
      warn "Resolver ${r}: A ${DOMAIN} ➜ ${a_recs} (≠ ${LB_IP})"
    fi
  elif [[ -n "${cname_rec}" ]]; then
    warn "Resolver ${r}: CNAME ${DOMAIN} ➜ ${cname_rec} (no A seen; apex records cannot be CNAME)"
  else
    warn "Resolver ${r}: No record for ${DOMAIN}"
  fi
done

# Authoritative zone & nameservers
read -r ZONE NSLIST < <(find_zone_and_ns "${DOMAIN}")
if [[ -n "${ZONE}" && -n "${NSLIST}" ]]; then
  provider="$(guess_dns_provider "${NSLIST}")"
  info "Authoritative zone: ${ZONE}"
  info "Authoritative nameservers:"
  while read -r ns; do [[ -n "$ns" ]] && echo "  - ${ns%.}" ; done <<< "${NSLIST}"
  info "Likely DNS provider: ${provider}"
else
  warn "Could not determine authoritative zone/NS for ${DOMAIN} (try installing 'dig')."
fi

# Cert status (helpful reminder)
cert_status="$(gcloud compute ssl-certificates describe "${CERT_NAME}" --format='value(managed.status)' 2>/dev/null || true)"
cert_status="${cert_status:-unknown}"

echo
if (( match_count == total )); then
  ok "DNS fully propagated for ${DOMAIN} (${match_count}/${total} resolvers match ${LB_IP})."
else
  warn "DNS not fully propagated for ${DOMAIN} (${match_count}/${total} resolvers match ${LB_IP})."
fi

if [[ "${cert_status}" != "ACTIVE" ]]; then
  warn "Managed certificate ${CERT_NAME} status: ${cert_status}. It becomes ACTIVE after DNS points to ${LB_IP} and propagates."
else
  ok "Managed certificate ${CERT_NAME} is ACTIVE."
fi

echo
ok "If needed, create/point an A record for ${DOMAIN} ➜ ${LB_IP} at your DNS host (see 'Likely DNS provider' above)."
echo
ok "Deployment complete."