#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:=us-central1}"

gcloud config set project "$PROJECT_ID"
gcloud services enable run.googleapis.com firestore.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com cloudscheduler.googleapis.com

gcloud firestore databases create --region="$REGION" || true

gcloud builds submit ./backend --tag "gcr.io/$PROJECT_ID/faire-lite-api"
gcloud run deploy faire-lite-api   --image "gcr.io/$PROJECT_ID/faire-lite-api"   --allow-unauthenticated   --region "$REGION"   --set-env-vars "GCP_PROJECT=$PROJECT_ID"   --update-secrets "LS_BASE_URL=LS_BASE_URL:latest,LS_API_KEY=LS_API_KEY:latest,OUTLET_ID=OUTLET_ID:latest"

API_URL=$(gcloud run services describe faire-lite-api --region "$REGION" --format='value(status.url)')

gcloud builds submit ./frontend --tag "gcr.io/$PROJECT_ID/faire-lite-ui"
gcloud run deploy faire-lite-ui   --image "gcr.io/$PROJECT_ID/faire-lite-ui"   --allow-unauthenticated   --region "$REGION"   --set-env-vars "VITE_API_URL=$API_URL"

echo "API URL: $API_URL"
gcloud run services list --platform=managed --region "$REGION"
