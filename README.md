# Faire → Lightspeed (Lite)

End‑to‑end toolchain to import Faire order CSVs, match items to Lightspeed Retail X‑Series products, create any missing products/suppliers, and submit a stock order (consignment) — with a simple Vue UI and FastAPI backend.

---

## TL;DR

* **UI on 8080**, **API on 8081**. UI points to API through `/public/config.js` at runtime:

  ```js
  window.RUNTIME_CONFIG = {API_URL: "${VITE_API_URL}/api"};
  ```
* **Faire `SKU` → Lightspeed `supplier_code`.**
  **Matched rows:** must include **LS `sku`** and **`product_id`**.
  **Missing rows:** must have **empty `sku`**, but include **`supplier_code`** and **`supplier_name`**; these will be created before adding to the consignment.
  **`wholesale_price` is required in both** arrays.
* Lightspeed product fetch at **`page_size=60000`** worked reliably and is fastest in practice.
* Avoid hard‑coding env; use `.env` (API) + `/config.js` (UI).
* On GCP behind HTTPS LB + IAP, grant users **`roles/iap.httpsResourceAccessor`** on both backends.

---
## Google Cloud Deployment
* create new project on google cloud
* Download the Google Cloud SDK if you dont have it. 
* Open Google Cloud Command prompt or login with git bash on VSCODE -- thats how I did it
```
# 0) Auth & project
gcloud auth login
gcloud config set project PROJECT_ID

# 1) Enable APIs
gcloud services enable run.googleapis.com compute.googleapis.com secretmanager.googleapis.com \
  iap.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
# (Cloud Run must exist before you make serverless NEGs / LB.) :contentReference[oaicite:0]{index=0}

# 2) Artifact Registry repo (use AR, not gcr.io)
gcloud artifacts repositories create apps --repository-format=docker --location=us-central1
# Build images to AR (Cloud Build pushes)
gcloud builds submit --tag us-central1-docker.pkg.dev/PROJECT_ID/apps/faire-lite-api
gcloud builds submit --tag us-central1-docker.pkg.dev/PROJECT_ID/apps/faire-lite-ui
# (Container Registry is shut down for writes; use Artifact Registry.) :contentReference[oaicite:1]{index=1}

# 3) Secrets
echo "https://YOUR_STORE.retail.lightspeed.app/api/2.0" | \
  gcloud secrets create LS_BASE_URL --replication-policy="automatic" --data-file=-
echo "YOUR_API_KEY" | \
  gcloud secrets create LS_API_KEY --replication-policy="automatic" --data-file=-
echo "YOUR-OUTLET-ID" | \
  gcloud secrets create OUTLET_ID --replication-policy="automatic" --data-file=-

# 4) (Recommended) Dedicated runtime SA for Cloud Run
SA="run-svc@PROJECT_ID.iam.gserviceaccount.com"
gcloud iam service-accounts create run-svc --display-name="Cloud Run runtime SA" || true
for s in LS_BASE_URL LS_API_KEY OUTLET_ID; do
  gcloud secrets add-iam-policy-binding $s \
    --member="serviceAccount:$SA" --role="roles/secretmanager.secretAccessor"
done
# (Cloud Run needs Secret Manager Secret Accessor.) :contentReference[oaicite:2]{index=2}

# 5) Deploy Cloud Run (must be BEFORE NEGs)
gcloud run deploy faire-lite-api \
  --image us-central1-docker.pkg.dev/PROJECT_ID/apps/faire-lite-api \
  --region us-central1 \
  --platform managed \
  --ingress internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --service-account $SA \
  --port 8081 \
  --update-secrets LS_BASE_URL=LS_BASE_URL:latest,LS_API_KEY=LS_API_KEY:latest,OUTLET_ID=OUTLET_ID:latest

gcloud run deploy faire-lite-ui \
  --image us-central1-docker.pkg.dev/PROJECT_ID/apps/faire-lite-ui \
  --region us-central1 \
  --platform managed \
  --ingress internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --service-account $SA \
  --port 8080 \
  --set-env-vars VITE_API_URL="https://your.custom.domain.com"

# 6) Create serverless NEGs (now that services exist)
gcloud compute network-endpoint-groups create ui-neg  \
  --region=us-central1 --network-endpoint-type=serverless --cloud-run-service=faire-lite-ui
gcloud compute network-endpoint-groups create api-neg \
  --region=us-central1 --network-endpoint-type=serverless --cloud-run-service=faire-lite-api
# (NEGs point at existing Cloud Run services.) :contentReference[oaicite:3]{index=3}

# 7) Backend services (external managed LB) + attach NEGs
gcloud compute backend-services create bs-faire-lite-ui  --global --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services create bs-faire-lite-api --global --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services add-backend bs-faire-lite-ui  \
  --global --network-endpoint-group=ui-neg  --network-endpoint-group-region=us-central1
gcloud compute backend-services add-backend bs-faire-lite-api \
  --global --network-endpoint-group=api-neg --network-endpoint-group-region=us-central1
# (External LB w/ serverless NEGs.) :contentReference[oaicite:4]{index=4}

# 8) Enable IAP on the backend services (or enable directly on Cloud Run)
#    Create OAuth client (Console) -> get CLIENT_ID / CLIENT_SECRET
gcloud iap web enable --resource-type=backend-services --service=bs-faire-lite-ui  \
  --oauth2-client-id=CLIENT_ID --oauth2-client-secret=CLIENT_SECRET
gcloud iap web enable --resource-type=backend-services --service=bs-faire-lite-api \
  --oauth2-client-id=CLIENT_ID --oauth2-client-secret=CLIENT_SECRET
# (Google also recommends enabling IAP at Cloud Run level; either works here.) :contentReference[oaicite:5]{index=5}

# 9) Grant IAP viewer access and let IAP call Cloud Run
PROJECT_NUMBER="$(gcloud projects describe PROJECT_ID --format='value(projectNumber)')"
IAP_SA="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"
gcloud run services add-iam-policy-binding faire-lite-ui \
  --region=us-central1 --member="serviceAccount:${IAP_SA}" --role="roles/run.invoker"
gcloud run services add-iam-policy-binding faire-lite-api \
  --region=us-central1 --member="serviceAccount:${IAP_SA}" --role="roles/run.invoker"
gcloud iap web add-iam-policy-binding --resource-type=backend-services --service=bs-faire-lite-ui \
  --member="user:user@googleworkspaceaddress.com" --role="roles/iap.httpsResourceAccessor"
gcloud iap web add-iam-policy-binding --resource-type=backend-services --service=bs-faire-lite-api \
  --member="user:user@googleworkspaceaddress.com" --role="roles/iap.httpsResourceAccessor"
# (Run Invoker to IAP SA, then grant IAP access to users.) :contentReference[oaicite:6]{index=6}

# 10) Global IP, URL map, cert, proxy, forwarding rule
gcloud compute addresses create ls-order-ip --global
LB_IP=$(gcloud compute addresses describe ls-order-ip --global --format="value(address)")

gcloud compute url-maps create ls-order-map --default-service=bs-faire-lite-ui
gcloud compute url-maps add-path-matcher ls-order-map \
  --path-matcher-name=api-matcher \
  --default-service=bs-faire-lite-ui \
  --new-hosts="your.custom.domain.com" \
  --backend-service-path-rules="/api/*=bs-faire-lite-api"

gcloud compute ssl-certificates create ls-order-cert --domains=your.custom.domain.com
gcloud compute target-https-proxies create ls-order-proxy \
  --url-map=ls-order-map --ssl-certificates=ls-order-cert
gcloud compute forwarding-rules create ls-order-forwarding-rule \
  --address=ls-order-ip --global --target-https-proxy=ls-order-proxy --ports=443

# 11) DNS
# Create/point A record for your.custom.domain.com -> $LB_IP
# (Managed cert goes ACTIVE only after DNS points at the LB.) :contentReference[oaicite:7]{index=7}

  ```

## What Worked / Key Decisions

* **Runtime config for UI** via `/config.js` (no rebuilds to change API URL).
* **Simple health checks:**

  * API: `GET /health` → `{ "ok": true }`
  * Quick smoke: `curl http://localhost:8081/health` and `curl http://localhost:8080/config.js`
* **Dockerized local dev** with host bridging: `host.docker.internal` → API from UI on Windows/Mac.
* **Lightspeed bulk fetch** with `page_size=60000` → fewer calls + faster matching.
* **Structured payloads** from UI submit (see schemas below) → deterministic API behavior.
* **UI UX tweaks:** preview panes auto‑expand with `inline-flex`; added submit‑time logging of arrays; optional **Auto‑create missing** checkbox.

## Gotchas / Things That Didn’t Work (and fixes)

* **Hard‑coded env** inside code → moved to `.env` (API) and `config.js` (UI).
* **Missing `wholesale_price`, `supplier_id/name`** in arrays → explicitly mapped into both `matched` and `missing`.
* **Wrong field in matched** (Faire `SKU` was echoed instead of LS `sku`) → ensure matched rows carry **LS `sku`** + `product_id`.
* **`/api/catalog/last-refresh` 404** in early local runs → confirm prefix/routing; expose as `GET /api/catalog/last-refresh` returning ISO timestamp.
* **IAP access issues** → add target users to **both** backends with `roles/iap.httpsResourceAccessor`; verify under *Network Services → Load balancing*.
* **Occasional 403 from Lightspeed** → resolved by restart + logging; keep exponential backoff + token refresh checks.
* **Currency inputs losing trailing zero** → present via formatter; store numeric; avoid `.number` if you want to preserve the displayed string.

---

## Architecture

* **UI:** Vue 3 single‑page app, containerized, served on **`8080`**. Reads runtime settings from `/config.js`.
* **API:** FastAPI on **`8081`**. Reads secrets from `.env`. Exposes REST endpoints for catalog refresh, matching, product/supplier creation, and consignment submission.
* **Data flow:** Faire CSV → UI parses & previews → calls API to fetch LS catalog → client‑side match → API creates missing entities (optional) → API builds & posts stock order (consignment).

---

## Local Development

### Prereqs

* Docker / Docker Desktop
* Node 18+ / npm 10+ (only if running UI locally outside container)

### Environment (.env for API)

```
# Lightspeed Retail X
LS_API_KEY=...
OUTLET_ID=...

# Behavior
DRY_RUN=true
PORT=8081
```

### UI runtime config (no rebuilds)

`ui/public/config.js`:

```js
window.RUNTIME_CONFIG = {
  API_URL: "http://host.docker.internal:8081"
};
```

### Build & Run (API)

```bash
# from repo root
docker build -t fastapi-api:local -f api/Dockerfile .
docker run --rm --env-file .env -e PORT=8081 -p 8081:8081 fastapi-api:local
# test
curl http://localhost:8081/health
```

### Build & Run (UI)

```bash
docker build -t faire-lite-ui:local -f ui/Dockerfile .
docker run --rm -p 8080:8080 faire-lite-ui:local
# test runtime config
curl http://localhost:8080/config.js
```

> If the UI image serves static files via Nginx, ensure `config.js` is baked into `/usr/share/nginx/html/config.js` **or** bind‑mount it over that path.

---

## Deploying to GCP

### 1) Build & Push

```bash
PROJECT_ID=your-gcp-project
REGION=us-central1
API_IMG=us-central1-docker.pkg.dev/$PROJECT_ID/faire-lite/fastapi-api:$(git rev-parse --short HEAD)
UI_IMG=us-central1-docker.pkg.dev/$PROJECT_ID/faire-lite/faire-ui:$(git rev-parse --short HEAD)

gcloud artifacts repositories create faire-lite --repository-format=docker --location=$REGION --description="Faire Lite images" || true

gcloud auth configure-docker $REGION-docker.pkg.dev

docker tag fastapi-api:local $API_IMG
docker push $API_IMG

docker tag faire-lite-ui:local $UI_IMG
docker push $UI_IMG
```

### 2) Cloud Run

```bash
gcloud run deploy bs-faire-lite-api \
  --image=$API_IMG \
  --region=$REGION \
  --cpu=1 --memory=512Mi \
  --port=8081 \
  --set-env-vars=LS_API_KEY=***,OUTLET_ID=***,DRY_RUN=false \
  --allow-unauthenticated=false

gcloud run deploy bs-faire-lite-ui \
  --image=$UI_IMG \
  --region=$REGION \
  --port=8080 \
  --allow-unauthenticated=false
```

### 3) HTTPS Load Balancer + IAP

* Network Services → **Load balancing** → create external HTTPS LB.
* **Backends:** add two serverless NEGs → `bs-faire-lite-ui` and `bs-faire-lite-api`.
* **Frontend:** set domain (e.g., `faire.lazypaddle.com`).
* **IAP:** enable and grant users **`roles/iap.httpsResourceAccessor`** on both backends. Verify health checks are green.

---

## API Endpoints (minimum contract)

* `GET /health` → `{ ok: true }`
* `GET /api/catalog/last-refresh` → `{ last_refresh: "2025-08-23T16:48:12Z" }`
* `POST /api/orders/consignment` → accepts combined items (matched + created) and builds the stock order

> Note: Exact routes may vary in your codebase; keep the above shape for UI integration.

---

## Data Mapping & Payloads

### Faire → Internal

| Faire CSV         | Internal field                              |
| ----------------- | ------------------------------------------- |
| `SKU`             | `supplier_code` (used to match LS products) |
| `Brand Name`      | `brand_name_f` and `supplier_name`          |
| `Product Name`    | `product_name_f`                            |
| `Wholesale Price` | `wholesale_price` (number)                  |
| `Quantity`        | `quantity` (number)                         |
| `Order Number`    | `order_number`                              |
| `Option Name`     | `option_name` (optional)                    |

### Matched row shape (UI → API)

```json
{
  "sku": "LS-12345",                // Lightspeed SKU
  "supplier_code": "FAIRE-ABC",     // Faire SKU
  "brand_name_f": "Acme Co",
  "supplier_id": "abcd-1234",
  "supplier_name": "Acme Co",
  "product_id": "ls-prod-7890",
  "product_name_f": "Widget / Blue",
  "wholesale_price": 2.25,
  "quantity": 6,
  "order_number": "FPHJQTHRE4"
}
```

### Missing row shape (UI → API)

```json
{
  "sku": "",                        // intentionally empty; created later
  "supplier_code": "FAIRE-XYZ",
  "brand_name_f": "Global Solutions, Inc",
  "supplier_id": null,               // may be filled by API
  "supplier_name": "Global Solutions, Inc",
  "product_id": null,
  "product_name_f": "Pearl Blue",
  "wholesale_price": 3.80,
  "quantity": 10,
  "order_number": "VAASBMMNJW"
}
```

> **Rules:** Faire `SKU` ⟶ LS `supplier_code`. Matched rows must include **LS `sku`** and **`product_id`**. Missing rows must have **empty `sku`**; API will ensure supplier/brand exist and create the product before building the consignment.

---

## UI Notes

* **Preview auto‑expand:** set container to `display: inline-flex; align-items: stretch;`.
* **Currency inputs:** display with `formatMoney`, store numeric; if preserving trailing zeros, bind to a string and normalize server‑side.
* **Logging:** before submit, log arrays for inspection:

```js
console.log("matched:", preview.value.matched);
console.log("missing:", preview.value.missing);
console.log("items:", items);
```

* **Auto‑create missing:** default to checked if any `missing.length > 0`.

---

## Troubleshooting

* **IAP 403:** user missing `roles/iap.httpsResourceAccessor` on one of the backends; verify in LB → Backends.
* **Random LS 403:** implement retry with backoff; verify API key; consider reducing concurrency.
* **`last-refresh` not shown:** confirm API route and that UI reads `last_refresh` ISO string.
* **Local UI → API:** use `host.docker.internal` from UI container; ensure CORS in FastAPI allows the UI origin during dev.

---

## Conventions

* Commit `package.json` **and** `package-lock.json`.
* Prefer `npm ci` in CI/Docker images.
* Keep one lockfile (don’t mix Yarn/Pnpm).
* Use ISO‑8601 UTC timestamps with trailing `Z`.

---

## License

Private/internal project.
