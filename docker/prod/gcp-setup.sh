#!/bin/bash
# One-time GCP setup for the Cloud Run deployment in
# .github/workflows/deploy-cloud-run.yml. Run this once (in Cloud Shell or a local
# gcloud, authenticated as the project owner), then copy the two printed values
# (WIF provider, service account email) into the repo's Actions variables.
set -e

PROJECT_ID="cotique-redmine"
REGION="us-central1"          # change if you want a different region
REPO_OWNER="cotique"
REPO_NAME="temp-redmine"
SA_NAME="redmine-deployer"
AR_REPO="redmine"
BUCKET="cotique-redmine-data"  # must be globally unique

gcloud config set project "$PROJECT_ID"
gcloud services enable run.googleapis.com artifactregistry.googleapis.com iamcredentials.googleapis.com sts.googleapis.com

gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION"
gcloud storage buckets create "gs://$BUCKET" --location="$REGION"

gcloud iam service-accounts create "$SA_NAME" --display-name="Redmine Cloud Run deployer"
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# A freshly created service account isn't immediately visible to the IAM policy API -
# binding a role to it right away reliably fails with "does not exist". Give it a
# few seconds to propagate.
sleep 15

gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/artifactregistry.writer"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectAdmin"

gcloud iam workload-identity-pools create github-pool --location=global --display-name="GitHub Actions pool"
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global --workload-identity-pool=github-pool \
  --display-name="GitHub provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='$REPO_OWNER/$REPO_NAME'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

WIF_POOL_ID=$(gcloud iam workload-identity-pools describe github-pool --location=global --format="value(name)")
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/$WIF_POOL_ID/attribute.repository/$REPO_OWNER/$REPO_NAME"

echo ""
echo "=== Set these as repo variables (Settings > Secrets and variables > Actions > Variables) ==="
echo "GCP_PROJECT_ID=$PROJECT_ID"
echo "GCP_REGION=$REGION"
echo "CLOUD_RUN_SERVICE=redmine"
echo "ARTIFACT_REGISTRY_REPO=$AR_REPO"
echo "GCS_DATA_BUCKET=$BUCKET"
echo "GCP_DEPLOYER_SERVICE_ACCOUNT=$SA_EMAIL"
echo -n "GCP_WORKLOAD_IDENTITY_PROVIDER="
gcloud iam workload-identity-pools providers describe github-provider --location=global --workload-identity-pool=github-pool --format="value(name)"
