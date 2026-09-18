#!/bin/bash
# Resume script for gcp-setup.sh - covers the IAM bindings and final output only,
# for when the first run got interrupted after the service account/WIF pool were
# already created. Safe to re-run: `|| true` on bindings that already exist.
set -e

PROJECT_ID="cotique-redmine"
REPO_OWNER="cotique"
REPO_NAME="temp-redmine"
BUCKET="cotique-redmine-data"
SA_EMAIL="redmine-deployer@cotique-redmine.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin" || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/artifactregistry.writer" || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser" || true
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectAdmin" || true

WIF_POOL_ID=$(gcloud iam workload-identity-pools describe github-pool --location=global --format="value(name)")
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/$WIF_POOL_ID/attribute.repository/$REPO_OWNER/$REPO_NAME" || true

echo ""
echo "=== Set these as repo variables (Settings > Secrets and variables > Actions > Variables) ==="
echo "GCP_PROJECT_ID=$PROJECT_ID"
echo "GCP_REGION=us-central1"
echo "CLOUD_RUN_SERVICE=redmine"
echo "ARTIFACT_REGISTRY_REPO=redmine"
echo "GCS_DATA_BUCKET=$BUCKET"
echo "GCP_DEPLOYER_SERVICE_ACCOUNT=$SA_EMAIL"
echo -n "GCP_WORKLOAD_IDENTITY_PROVIDER="
gcloud iam workload-identity-pools providers describe github-provider --location=global --workload-identity-pool=github-pool --format="value(name)"
