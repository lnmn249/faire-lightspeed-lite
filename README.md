# Faire → Lightspeed (Retail X) — Cloud Run “Lite” (Fixed)

This package applies the audit fixes:
- Cloud Run `$PORT` binding for **both** backend and frontend (Nginx).
- **Runtime** API URL injection for the SPA via `config.js` (no build-time bake-in).
- Safer **CORS** (no wildcard with credentials).
- Firestore **batch chunking** (≤500 ops per commit).
- Secret Manager canonical access pattern.
- Cleaner deploy flow.

## Quick start

```bash
# prereqs
export PROJECT_ID=YOUR_GCP_PROJECT
export REGION=us-central1

gcloud config set project $PROJECT_ID
gcloud services enable run.googleapis.com firestore.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com cloudscheduler.googleapis.com

# Firestore (Native)
gcloud firestore databases create --region=$REGION || true

# Secrets
gcloud secrets create LS_BASE_URL --replication-policy=automatic || true
printf "%s" "https://<your>.retail.lightspeed.app/api/2.0" | gcloud secrets versions add LS_BASE_URL --data-file=-

gcloud secrets create LS_API_KEY --replication-policy=automatic || true
printf "%s" "<your_x_series_api_key>" | gcloud secrets versions add LS_API_KEY --data-file=-

gcloud secrets create OUTLET_ID --replication-policy=automatic || true
printf "%s" "<your_outlet_id>" | gcloud secrets versions add OUTLET_ID --data-file=-

# Backend
gcloud builds submit ./backend --tag gcr.io/$PROJECT_ID/faire-lite-api
gcloud run deploy faire-lite-api   --image gcr.io/$PROJECT_ID/faire-lite-api   --allow-unauthenticated   --region $REGION   --set-env-vars GCP_PROJECT=$PROJECT_ID   --update-secrets LS_BASE_URL=LS_BASE_URL:latest,LS_API_KEY=LS_API_KEY:latest,OUTLET_ID=OUTLET_ID:latest

# Frontend (runtime-configured)
API_URL=$(gcloud run services describe faire-lite-api --region $REGION --format='value(status.url)')
gcloud builds submit ./frontend --tag gcr.io/$PROJECT_ID/faire-lite-ui
gcloud run deploy faire-lite-ui   --image gcr.io/$PROJECT_ID/faire-lite-ui   --allow-unauthenticated   --region $REGION   --set-env-vars VITE_API_URL=$API_URL

# Optional: Scheduler
gcloud scheduler jobs create http faire-lite-catalog-refresh   --schedule="0 3 * * *"   --uri="$API_URL/catalog/refresh"   --http-method=POST
```
