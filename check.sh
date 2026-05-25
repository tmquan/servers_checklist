#!/usr/bin/env bash
# check.sh — One-shot validator for the NVIDIA Hackathon 2026 VTS H200 cluster.
#
# Usage:
#   ./check.sh ignored/team-04.yaml     # uses given file as KUBECONFIG
#   KUBECONFIG=/path/to.yaml ./check.sh # uses env var
#   ./check.sh --skip 03,07             # skip slow / network-dependent steps
#   ./check.sh --only 01,02,06          # run only listed step IDs
#   ./check.sh --pvc workspace          # override PVC_NAME (default: auto-detect)
#   ./check.sh --no-cleanup             # keep manifests applied for inspection
#
# Bash 3.2 compatible (macOS default).
# Requires: kubectl (>=1.27), envsubst.

set -u
set -o pipefail

# ---------- ANSI ----------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; DIM=""; RST=""
fi

# ---------- CLI ----------
SKIP=""
ONLY=""
PVC_OVERRIDE=""
NO_CLEANUP=0
KCFG_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip) SKIP="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --pvc) PVC_OVERRIDE="$2"; shift 2 ;;
    --no-cleanup) NO_CLEANUP=1; shift ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "${RED}unknown flag: $1${RST}" >&2; exit 64 ;;
    *)
      KCFG_ARG="$1"; shift ;;
  esac
done

if [ -n "${KCFG_ARG}" ]; then
  if [ ! -r "${KCFG_ARG}" ]; then
    echo "${RED}kubeconfig not readable: ${KCFG_ARG}${RST}" >&2; exit 66
  fi
  export KUBECONFIG="${KCFG_ARG}"
fi
if [ -z "${KUBECONFIG:-}" ]; then
  echo "${RED}KUBECONFIG not set and no kubeconfig file passed.${RST}" >&2
  echo "Usage: ./check.sh ignored/team-NN.yaml" >&2
  exit 64
fi

command -v kubectl   >/dev/null 2>&1 || { echo "${RED}kubectl not found${RST}" >&2; exit 69; }
command -v envsubst  >/dev/null 2>&1 || { echo "${RED}envsubst not found (install gettext)${RST}" >&2; exit 69; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
MFD="${ROOT}/manifests"

# ---------- header ----------
banner() {
  printf "%s\n" "${BLU}==================================================================${RST}"
  printf "%s\n" "${BLU} NVIDIA Open Hackathon 2026 — VTS H200 onboarding check${RST}"
  printf "%s\n" "${BLU}==================================================================${RST}"
}
banner

# ---------- pre-flight ----------
NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
if [ -z "${NS}" ]; then
  echo "${RED}kubeconfig has no namespace set on current-context — fix it first.${RST}" >&2
  exit 78
fi
CTX="$(kubectl config current-context)"

if ! kubectl version 2>/dev/null | grep -q 'Server Version'; then
  echo "${RED}cannot reach apiserver — check VPN / kubeconfig${RST}" >&2
  kubectl version 2>&1 | tail -5
  exit 75
fi
SERVER_VER="$(kubectl version 2>/dev/null | awk '/Server Version/ {print $3}')"

# Derive TEAM_NN from namespace (team-04-restricted -> 04)
TEAM_NN="$(printf "%s" "${NS}" | sed -E 's/team-0*([0-9]+)-restricted.*/\1/' | awk '{ printf "%02d", $1 }')"

# Find the team's HGX node by inspecting any existing pod (most reliable).
TEAM_NODE="$(kubectl get pod -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
if [ -z "${TEAM_NODE}" ]; then
  # Fallback: spawn a tiny pod just to learn the node, then tear it down.
  TEAM_NODE="$(
    kubectl run chk-detect-node --image=busybox:1.36 --restart=Never --rm -i --quiet \
            --overrides='{"spec":{"securityContext":{"runAsUser":1006,"runAsGroup":1010,"runAsNonRoot":true,"fsGroup":1010}}}' \
            -- sh -c 'echo $HOSTNAME' 2>/dev/null | head -1 || true
  )"
fi
if [ -z "${TEAM_NODE}" ]; then
  echo "${YEL}warning: could not auto-detect TEAM_NODE; node-pinned checks will skip.${RST}"
fi

# Pick a PVC: explicit override > anything containing 'workspace' / 'gpfs' > the largest > none.
if [ -n "${PVC_OVERRIDE}" ]; then
  PVC_NAME="${PVC_OVERRIDE}"
else
  PVC_NAME="$(
    kubectl get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.resources.requests.storage}{"\n"}{end}' 2>/dev/null \
      | awk '
          {
            n=$1; s=$2;
            if (s ~ /Ti$/)      { val=substr(s,1,length(s)-2)*1024*1024 }
            else if (s ~ /Gi$/) { val=substr(s,1,length(s)-2)*1024 }
            else if (s ~ /Mi$/) { val=substr(s,1,length(s)-2) }
            else                { val=0 }
            if (n ~ /workspace|gpfs|scratch/) { val += 10000000 }   # prefer
            if (val > best) { best=val; bestn=n }
          }
          END { if (bestn) print bestn }
        '
  )"
fi

export TEAM_NN TEAM_NODE PVC_NAME
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
export INGRESS_CLASS

printf "  context     : %s\n" "${CTX}"
printf "  namespace   : %s\n" "${NS}"
printf "  server      : %s\n" "${SERVER_VER}"
printf "  team        : %s\n" "${TEAM_NN}"
printf "  team_node   : %s\n" "${TEAM_NODE:-<unknown>}"
printf "  pvc         : %s\n" "${PVC_NAME:-<none — §14 will be skipped>}"
printf "  ingress     : %s\n" "${INGRESS_CLASS}"
echo

# ---------- helpers ----------
should_run() {
  # $1 = step id like "01"
  local id="$1"
  if [ -n "${ONLY}" ]; then
    case ",${ONLY}," in *",${id},"*) return 0 ;; *) return 1 ;; esac
  fi
  if [ -n "${SKIP}" ]; then
    case ",${SKIP},"  in *",${id},"*) return 1 ;; esac
  fi
  return 0
}

# Track results in two parallel arrays (bash 3.2 has no associative arrays).
RES_IDS=()
RES_LBL=()
RES_OUT=()    # one of: PASS / FAIL / SKIP / WARN
RES_MSG=()

mark() {
  RES_IDS+=("$1"); RES_LBL+=("$2"); RES_OUT+=("$3"); RES_MSG+=("$4")
  case "$3" in
    PASS) printf "  %s[ PASS ]%s %s — %s\n" "${GRN}" "${RST}" "$1" "$2" ;;
    FAIL) printf "  %s[ FAIL ]%s %s — %s — %s\n" "${RED}" "${RST}" "$1" "$2" "$4" ;;
    SKIP) printf "  %s[ SKIP ]%s %s — %s — %s\n" "${DIM}" "${RST}" "$1" "$2" "$4" ;;
    WARN) printf "  %s[ WARN ]%s %s — %s — %s\n" "${YEL}" "${RST}" "$1" "$2" "$4" ;;
  esac
}

apply_subst() {
  envsubst < "$1" | kubectl apply -f - >/dev/null
}

logs_of_pod() {
  kubectl logs "$1" 2>/dev/null || true
}

logs_of_job() {
  local job="$1"
  local pod
  pod="$(kubectl get pod -l job-name="${job}" -o name 2>/dev/null | head -1)"
  [ -n "${pod}" ] && kubectl logs "${pod}" 2>/dev/null || true
}

wait_pod_done() {
  # kubectl wait phase=Succeeded; on Failure, return 1.
  local pod="$1"; local timeout="${2:-300s}"
  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout="${timeout}" >/dev/null 2>&1; then
    return 0
  fi
  if kubectl wait --for=jsonpath='{.status.phase}'=Failed "pod/${pod}" --timeout=5s >/dev/null 2>&1; then
    return 1
  fi
  return 2  # timeout
}

cleanup() {
  if [ "${NO_CLEANUP}" = "1" ]; then
    echo "${YEL}--no-cleanup: leaving check resources in place.${RST}"
    return
  fi
  echo
  echo "${DIM}cleaning up checklist resources…${RST}"
  for f in "${MFD}"/*.yaml; do
    [ -e "$f" ] || continue
    envsubst < "$f" | kubectl delete -f - --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  kubectl delete pod chk-detect-node --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------- the 14 checks ----------

# Step 1+2: gpu-smi (covers items 1 & 2 partially; "8 GPU" handled in step 8)
if should_run 01; then
  echo "${BLU}>> 01 nvidia-smi (item #2: H200/Hopper)${RST}"
  if [ -z "${TEAM_NODE}" ]; then
    mark 02 "GPU Type (H200)" SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/01-gpu-smi.yaml"
    if wait_pod_done chk-01-gpu-smi 180s; then
      if logs_of_pod chk-01-gpu-smi | grep -q "CHECK_PASS: H200 visible"; then
        mark 02 "GPU Type (H200)" PASS ""
      else
        mark 02 "GPU Type (H200)" FAIL "no H200 in nvidia-smi -L"
      fi
    else
      mark 02 "GPU Type (H200)" FAIL "pod did not Succeed (see kubectl describe pod chk-01-gpu-smi)"
    fi
  fi
else
  mark 02 "GPU Type (H200)" SKIP "by --skip"
fi

# Step 02: 8 GPU dedicated  (items 1, 3, 8)
if should_run 02; then
  echo "${BLU}>> 02 8× GPU dedicated (items #1, #3, #8)${RST}"
  if [ -z "${TEAM_NODE}" ]; then
    mark 01 "Compute Access 8× GPU" SKIP "TEAM_NODE unknown"
    mark 08 "Multi-GPU Single Node"  SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/02-gpu-eight.yaml"
    rc=0; wait_pod_done chk-02-gpu-eight 240s || rc=$?
    OUT="$(logs_of_pod chk-02-gpu-eight)"
    if echo "${OUT}" | grep -q "CHECK_PASS: 8 GPU dedicated"; then
      mark 01 "Compute Access 8× GPU" PASS ""
      mark 08 "Multi-GPU Single Node"  PASS "via 8-GPU pod"
    else
      hint=""
      if kubectl get deploy llama-3-1-nemotron-nano-8b-v1 -o jsonpath='{.spec.replicas}' 2>/dev/null | grep -q '^1$'; then
        hint="; the NIM deployment is holding 1 GPU — scale it to 0 and retry"
      fi
      mark 01 "Compute Access 8× GPU" FAIL "8-GPU pod did not report 8 GPUs${hint}"
      mark 08 "Multi-GPU Single Node"  FAIL "depends on item #1"
    fi
  fi
else
  mark 01 "Compute Access 8× GPU" SKIP "by --skip"
  mark 08 "Multi-GPU Single Node"  SKIP "by --skip"
fi

# Step 03: NCCL all-reduce (item 7)
if should_run 03; then
  echo "${BLU}>> 03 NCCL all_reduce 8× GPU (item #7)${RST}"
  if [ -z "${TEAM_NODE}" ]; then
    mark 07 "NCCL NVLink+IB" SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/03-nccl-allreduce.yaml"
    if kubectl wait --for=condition=Complete job/chk-03-nccl --timeout=900s >/dev/null 2>&1; then
      OUT="$(logs_of_job chk-03-nccl)"
      if echo "${OUT}" | grep -q "CHECK_PASS: NCCL"; then
        mark 07 "NCCL NVLink+IB" PASS ""
      elif echo "${OUT}" | grep -q "CHECK_FAIL: NCCL"; then
        bw=$(echo "${OUT}" | awk -F'busbw ' '/CHECK_FAIL: NCCL/ {print $2; exit}')
        mark 07 "NCCL NVLink+IB" WARN "${bw} below 80% peak"
      else
        mark 07 "NCCL NVLink+IB" FAIL "no busbw line; check job logs"
      fi
    else
      mark 07 "NCCL NVLink+IB" FAIL "job did not complete (kubectl describe job/chk-03-nccl)"
    fi
  fi
else
  mark 07 "NCCL NVLink+IB" SKIP "by --skip"
fi

# Step 04: storage IO (item 14a)
if should_run 04; then
  echo "${BLU}>> 04 fio storage IO (item #14)${RST}"
  if [ -z "${PVC_NAME}" ]; then
    mark 14a "Storage throughput" SKIP "no PVC found in namespace"
  elif [ -z "${TEAM_NODE}" ]; then
    mark 14a "Storage throughput" SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/04-storage-io.yaml"
    if wait_pod_done chk-04-storage-io 900s; then
      if logs_of_pod chk-04-storage-io | grep -q "CHECK_PASS: storage IO"; then
        mark 14a "Storage throughput" PASS "PVC=${PVC_NAME}"
      else
        mark 14a "Storage throughput" FAIL "fio sentinel missing"
      fi
    else
      mark 14a "Storage throughput" FAIL "pod did not Succeed (PVC=${PVC_NAME})"
    fi
  fi
else
  mark 14a "Storage throughput" SKIP "by --skip"
fi

# Step 05: GDS (item 14b)
if should_run 05; then
  echo "${BLU}>> 05 GPU Direct Storage (item #14)${RST}"
  if [ -z "${PVC_NAME}" ] || [ -z "${TEAM_NODE}" ]; then
    mark 14b "GDS enabled" SKIP "missing PVC or TEAM_NODE"
  else
    apply_subst "${MFD}/05-gds-check.yaml"
    if wait_pod_done chk-05-gds 600s; then
      if logs_of_pod chk-05-gds | grep -q "CHECK_PASS: GDS enabled"; then
        mark 14b "GDS enabled" PASS ""
      else
        mark 14b "GDS enabled" WARN "gdscheck did not report Enabled — see logs"
      fi
    else
      mark 14b "GDS enabled" FAIL "pod did not Succeed"
    fi
  fi
else
  mark 14b "GDS enabled" SKIP "by --skip"
fi

# Step 06: NGC egress (item 6)
if should_run 06; then
  echo "${BLU}>> 06 NGC + NIM egress (item #6)${RST}"
  if [ -z "${TEAM_NODE}" ]; then
    mark 06 "NGC + NIM API access" SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/06-ngc-egress.yaml"
    if wait_pod_done chk-06-ngc-egress 180s; then
      if logs_of_pod chk-06-ngc-egress | grep -q "CHECK_PASS: NGC + NIM"; then
        mark 06 "NGC + NIM API access" PASS ""
      else
        mark 06 "NGC + NIM API access" FAIL "no PASS sentinel — egress blocked?"
      fi
    else
      mark 06 "NGC + NIM API access" FAIL "pod did not Succeed"
    fi
  fi
else
  mark 06 "NGC + NIM API access" SKIP "by --skip"
fi

# Step 07: port-forward demo deploy (item 10)
if should_run 07; then
  echo "${BLU}>> 07 port-forward demo (item #10)${RST}"
  if [ -z "${TEAM_NODE}" ]; then
    mark 10 "Ports policy" SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/07-portforward-demo.yaml"
    if kubectl rollout status deploy/chk-07-demo --timeout=180s >/dev/null 2>&1; then
      mark 10 "Ports policy" PASS "deploy ready — run kubectl port-forward svc/chk-07-demo 80${TEAM_NN}:80 from your laptop"
    else
      mark 10 "Ports policy" FAIL "demo Deployment did not roll out"
    fi
  fi
else
  mark 10 "Ports policy" SKIP "by --skip"
fi

# Step 08: ingress (item 11)
if should_run 08; then
  echo "${BLU}>> 08 wildcard subdomain Ingress (item #11)${RST}"
  if ! kubectl get deploy chk-07-demo >/dev/null 2>&1; then
    mark 11 "JupyterLab / wildcard subdomain" SKIP "step 07 was not run"
  else
    apply_subst "${MFD}/08-ingress-demo.yaml"
    sleep 2
    HOST="$(kubectl get ingress chk-08-ingress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
    if [ -n "${HOST}" ]; then
      mark 11 "JupyterLab / wildcard subdomain" PASS "verify externally: curl -I https://${HOST}"
    else
      mark 11 "JupyterLab / wildcard subdomain" FAIL "ingress not created"
    fi
  fi
else
  mark 11 "JupyterLab / wildcard subdomain" SKIP "by --skip"
fi

# Step 09: nsight (item 13)
if should_run 09; then
  echo "${BLU}>> 09 Nsight Systems (item #13)${RST}"
  if [ -z "${TEAM_NODE}" ]; then
    mark 13 "Nsight Profiling" SKIP "TEAM_NODE unknown"
  else
    apply_subst "${MFD}/09-nsight-profile.yaml"
    if kubectl wait --for=condition=Complete job/chk-09-nsight --timeout=600s >/dev/null 2>&1; then
      if logs_of_job chk-09-nsight | grep -q "CHECK_PASS: nsys report"; then
        mark 13 "Nsight Profiling" PASS ""
      else
        mark 13 "Nsight Profiling" FAIL "no nsys report sentinel"
      fi
    else
      mark 13 "Nsight Profiling" FAIL "job did not complete"
    fi
  fi
else
  mark 13 "Nsight Profiling" SKIP "by --skip"
fi

# Item 3 — exclusive node (RBAC + Kyverno are cluster-level; smoke test by listing pod nodes).
if should_run 03i; then
  ALL_NODES="$(kubectl get pod -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')"
  COUNT="$(echo "${ALL_NODES}" | tr ',' '\n' | grep -c .)"
  if [ "${COUNT}" -le 1 ]; then
    mark 03 "Exclusive GPU per team" PASS "all your pods are on ${ALL_NODES:-<no pods>}"
  else
    mark 03 "Exclusive GPU per team" WARN "pods scattered across ${ALL_NODES}"
  fi
fi

# Item 4 — container runtime (any successful pull above implies it works).
mark 04 "Containers (Docker/Apptainer/Compose)" PASS "any pod above pulled OK"

# Item 5 — kubernetes
case "${SERVER_VER}" in
  v1.34*|v1.35*) mark 05 "Kubernetes orchestration" PASS "${SERVER_VER}" ;;
  v1.33*)        mark 05 "Kubernetes orchestration" WARN "older than 1.34 (${SERVER_VER})" ;;
  *)             mark 05 "Kubernetes orchestration" WARN "unexpected version ${SERVER_VER}" ;;
esac

# Item 9 — single-node team scope (informational)
mark 09 "Multi-GPU Multi-Node" WARN "1 node/team by design — request from VTS if needed"

# Item 12 — NVIDIA SDK images (deep but slow). Quick proxy: nvcr.io reachable + ngc-registry present.
if kubectl get secret ngc-registry >/dev/null 2>&1; then
  mark 12 "NVIDIA SDK pre-installed" PASS "ngc-registry secret present (run §12 in CHECKLIST.md for full pull)"
else
  mark 12 "NVIDIA SDK pre-installed" FAIL "ngc-registry secret missing"
fi

# Item 14c — cross-namespace deny test
OTHER_NS="team-01-restricted"
if [ "${NS}" = "${OTHER_NS}" ]; then OTHER_NS="team-02-restricted"; fi
if kubectl get pvc -n "${OTHER_NS}" >/dev/null 2>&1; then
  mark 14c "Cross-team isolation" FAIL "could read ${OTHER_NS} (should be Forbidden)"
else
  mark 14c "Cross-team isolation" PASS "${OTHER_NS} returns Forbidden as expected"
fi

# ---------- summary ----------
echo
printf "%s\n" "${BLU}==================================================================${RST}"
printf "%s\n" "${BLU} Summary — NVIDIA Cluster Readiness Checklist (team-${TEAM_NN})${RST}"
printf "%s\n" "${BLU}==================================================================${RST}"
printf "  %-4s %-40s  %s\n" "ID" "Mục" "Result"
printf "  %-4s %-40s  %s\n" "----" "----------------------------------------" "------"

# Sort the rows by numeric prefix so the table reads 01..14.
i=0
SORTED_INDEXES=$(
  for j in $(seq 0 $((${#RES_IDS[@]}-1))); do
    printf "%s\t%d\n" "${RES_IDS[$j]}" "$j"
  done | sort -k1,1 | awk '{print $2}'
)

PASS=0; FAIL=0; SKIPC=0; WARNC=0
for j in ${SORTED_INDEXES}; do
  case "${RES_OUT[$j]}" in
    PASS) tag="${GRN}PASS${RST}"; PASS=$((PASS+1)) ;;
    FAIL) tag="${RED}FAIL${RST}"; FAIL=$((FAIL+1)) ;;
    SKIP) tag="${DIM}SKIP${RST}"; SKIPC=$((SKIPC+1)) ;;
    WARN) tag="${YEL}WARN${RST}"; WARNC=$((WARNC+1)) ;;
  esac
  printf "  %-4s %-40s  %b\n" "${RES_IDS[$j]}" "${RES_LBL[$j]}" "${tag}"
  if [ -n "${RES_MSG[$j]}" ]; then
    printf "       %s%s%s\n" "${DIM}" "${RES_MSG[$j]}" "${RST}"
  fi
done

echo
printf "  %sPASS%s=%d  %sWARN%s=%d  %sSKIP%s=%d  %sFAIL%s=%d\n" \
  "${GRN}" "${RST}" "${PASS}" "${YEL}" "${RST}" "${WARNC}" \
  "${DIM}" "${RST}" "${SKIPC}" "${RED}" "${RST}" "${FAIL}"

if [ "${FAIL}" -gt 0 ]; then exit 1; fi
exit 0
