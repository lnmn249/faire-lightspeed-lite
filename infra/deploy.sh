#!/usr/bin/env bash
set -euo pipefail

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
# 0) Auth & project
#############################################
require gcloud
info "Activating project: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

#############################################
# 1) Enable APIs
#############################################
info "Enabling required services/APIs…"
gcloud services enable \
  run.googleapis.com \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com

#############################################
# 2) Artifact Registry repo + build images
#############################################
info "Ensuring Artifact Registry repo exists: ${REPO}"
gcloud artifacts repositories describe "${REPO}" --location="${REGION}" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "${REPO}" --repository-format=docker --location="${REGION}"

info "Building & pushing images (API & UI) to Artifact Registry…"
# Adjust build contexts if your Dockerfiles live in subfolders:
#   ./backend  for API,  ./frontend for UI
gcloud builds submit ./backend  --tag "${AR_HOST}/${PROJECT_ID}/${REPO}/${SVC_API}:latest"
gcloud builds submit ./frontend --tag "${AR_HOST}/${PROJECT_ID}/${REPO}/${SVC_UI}:latest"

#############################################
# 3) Secrets
#############################################
create_or_add_secret(){
  local name="$1" value="$2"
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    info "Adding new version to secret: $name"
    printf "%s" "$value" | gcloud secrets versions add "$name" --data-file=-
  else
    info "Creating secret: $name"
    printf "%s" "$value" | gcloud secrets create "$name" --replication-policy="automatic" --data-file=-
  fi
}
create_or_add_secret "LS_BASE_URL" "${STORE_BASE_URL}"
create_or_add_secret "LS_API_KEY" "${LS_API_KEY}"
create_or_add_secret "OUTLET_ID"  "${OUTLET_ID}"

#############################################
# 4) Runtime Service Account & Secret access
#############################################
info "Ensuring Cloud Run runtime service account: ${RUN_SA}"
gcloud iam service-accounts describe "${RUN_SA}" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "${RUN_SA_NAME}" --display-name="Cloud Run runtime SA"

for s in LS_BASE_URL LS_API_KEY OUTLET_ID; do
  info "Granting Secret Manager access for ${RUN_SA} on ${s}"
  gcloud secrets add-iam-policy-binding "${s}" \
    --member="serviceAccount:${RUN_SA}" \
    --role="roles/secretmanager.secretAccessor" >/dev/null
done

#############################################
# 5) Deploy Cloud Run (must exist before NEGs)
#############################################
info "Deploying Cloud Run service: ${SVC_API}"
gcloud run deploy "${SVC_API}" \
  --image "${AR_HOST}/${PROJECT_ID}/${REPO}/${SVC_API}:latest" \
  --region "${REGION}" \
  --platform managed \
  --ingress internal-and-cloud-load-balancing \
  --allow-unauthenticated \
  --service-account "${RUN_SA}" \
  --port 8081 \
  --update-secrets LS_BASE_URL=LS_BASE_URL:latest,LS_API_KEY=LS_API_KEY:latest,OUTLET_ID=OUTLET_ID:latest

info "Deploying Cloud Run service: ${SVC_UI}"
gcloud run deploy "${SVC_UI}" \
  --image "${AR_HOST}/${PROJECT_ID}/${REPO}/${SVC_UI}:latest" \
  --region "${REGION}" \
  --platform managed \
  --ingress internal-and-cloud-load-balancing \
  --allow-unauthenticated \
  --service-account "${RUN_SA}" \
  --port 8080 \
  --set-env-vars "VITE_API_URL=https://${DOMAIN}"

#############################################
# 6) Serverless NEGs (need existing Cloud Run)
#############################################
info "Creating serverless NEGs…"
gcloud compute network-endpoint-groups describe "${NEG_UI}"  --region="${REGION}" >/dev/null 2>&1 || \
  gcloud compute network-endpoint-groups create "${NEG_UI}" \
    --region="${REGION}" --network-endpoint-type=serverless --cloud-run-service="${SVC_UI}"

gcloud compute network-endpoint-groups describe "${NEG_API}" --region="${REGION}" >/dev/null 2>&1 || \
  gcloud compute network-endpoint-groups create "${NEG_API}" \
    --region="${REGION}" --network-endpoint-type=serverless --cloud-run-service="${SVC_API}"

#############################################
# 7) Backend services + attach NEGs
#############################################
info "Creating backend services…"
gcloud compute backend-services describe "${BS_UI}"  --global >/dev/null 2>&1 || \
  gcloud compute backend-services create   "${BS_UI}"  --global --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services describe "${BS_API}" --global >/dev/null 2>&1 || \
  gcloud compute backend-services create   "${BS_API}" --global --load-balancing-scheme=EXTERNAL_MANAGED

info "Attaching NEGs to backend services…"
# (OK if already added)
gcloud compute backend-services add-backend "${BS_UI}"  --global \
  --network-endpoint-group="${NEG_UI}"  --network-endpoint-group-region="${REGION}" || true
gcloud compute backend-services add-backend "${BS_API}" --global \
  --network-endpoint-group="${NEG_API}" --network-endpoint-group-region="${REGION}" || true

#############################################
# 8) IAP enable (Backend Services level)
#############################################
if [[ -n "${IAP_CLIENT_ID}" && -n "${IAP_CLIENT_SECRET}" ]]; then
  info "Enabling IAP on backend services…"
  gcloud iap web enable --resource-type=backend-services --service="${BS_UI}"  \
    --oauth2-client-id="${IAP_CLIENT_ID}" --oauth2-client-secret="${IAP_CLIENT_SECRET}"
  gcloud iap web enable --resource-type=backend-services --service="${BS_API}" \
    --oauth2-client-id="${IAP_CLIENT_ID}" --oauth2-client-secret="${IAP_CLIENT_SECRET}"
else
  warn "IAP_CLIENT_ID/SECRET not set — skipping IAP enable. Set them and re-run this section if needed."
fi

#############################################
# 9) IAP bindings (allow IAP to call Run, grant user access)
#############################################
info "Binding IAP → Cloud Run invoker & granting user access…"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
IAP_SA="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"

gcloud run services add-iam-policy-binding "${SVC_UI}" \
  --region="${REGION}" --member="serviceAccount:${IAP_SA}" --role="roles/run.invoker" >/dev/null
gcloud run services add-iam-policy-binding "${SVC_API}" \
  --region="${REGION}" --member="serviceAccount:${IAP_SA}" --role="roles/run.invoker" >/dev/null

if [[ -n "${IAP_USER_EMAIL}" ]]; then
  gcloud iap web add-iam-policy-binding --resource-type=backend-services --service="${BS_UI}" \
    --member="user:${IAP_USER_EMAIL}" --role="roles/iap.httpsResourceAccessor" >/dev/null
  gcloud iap web add-iam-policy-binding --resource-type=backend-services --service="${BS_API}" \
    --member="user:${IAP_USER_EMAIL}" --role="roles/iap.httpsResourceAccessor" >/dev/null
else
  warn "IAP_USER_EMAIL not set — skipping IAP viewer binding."
fi

#############################################
# 10) LB: IP, URL map, cert, proxy, forwarding rule
#############################################
info "Allocating global IP (if needed)…"
gcloud compute addresses describe "${IP_NAME}" --global >/dev/null 2>&1 || \
  gcloud compute addresses create "${IP_NAME}" --global
LB_IP="$(gcloud compute addresses describe "${IP_NAME}" --global --format='value(address)')"
ok "LB IP: ${LB_IP}"

info "Creating/patching URL map…"
gcloud compute url-maps describe "${URL_MAP}" >/dev/null 2>&1 || \
  gcloud compute url-maps create "${URL_MAP}" --default-service="${BS_UI}"

# Add path matcher (idempotent-ish)
gcloud compute url-maps add-path-matcher "${URL_MAP}" \
  --path-matcher-name="${PATH_MATCHER}" \
  --default-service="${BS_UI}" \
  --new-hosts="${DOMAIN}" \
  --backend-service-path-rules="/api/*=${BS_API}" || true

info "Creating managed SSL certificate…"
gcloud compute ssl-certificates describe "${CERT_NAME}" >/dev/null 2>&1 || \
  gcloud compute ssl-certificates create "${CERT_NAME}" --domains="${DOMAIN}"

info "Creating HTTPS proxy…"
gcloud compute target-https-proxies describe "${PROXY_NAME}" >/dev/null 2>&1 || \
  gcloud compute target-https-proxies create "${PROXY_NAME}" \
    --url-map="${URL_MAP}" --ssl-certificates="${CERT_NAME}"

info "Creating global forwarding rule…"
gcloud compute forwarding-rules describe "${FR_NAME}" --global >/dev/null 2>&1 || \
  gcloud compute forwarding-rules create "${FR_NAME}" \
    --address="${IP_NAME}" --global --target-https-proxy="${PROXY_NAME}" --ports=443

#############################################
# 11) DNS reminder
#############################################
echo
ok "Create/point an A record for ${DOMAIN} ➜ ${LB_IP}"
ok "The managed cert will become ACTIVE once DNS resolves to the LB."
echo
ok "Deployment complete."
