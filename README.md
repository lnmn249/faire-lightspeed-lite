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
* Use the deploy_gCloud.sh file 

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
