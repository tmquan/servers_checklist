# NVIDIA Open Hackathon 2026 — Server Onboarding Checklist

> Bilingual runbook (Vietnamese headings, English commands/notes).
> Đối chiếu **NVIDIA Cluster Readiness Checklist** — VTS H200 cluster.
> Source spec: `ignored/NVIDIA Hackathon 2026 — Phương án kỹ thuật cho VTS.pdf`.

This document walks a newly joining team through validating its slice of the
cluster (1 HGX node, 8× H200, 10 TiB GPFS, NGC/NIM access, port-forward demo,
ingress subdomain, Nsight). Every section maps to one row of the readiness
table on page 7 of the spec.

You can either:
- run everything end-to-end with the validator: `./check.sh ignored/team-NN.yaml`, or
- step through this file manually — copy-paste the commands per section.

> Note: drop your kubeconfig under `ignored/` — that directory is git-ignored
> so the bearer token never leaks into the repo.

---

## 0. Chuẩn bị / Pre-flight

**Mục tiêu**: kubeconfig hoạt động, đúng namespace, đúng cluster.

```bash
# Use the kubeconfig the organizers gave you (kept under ignored/)
export KUBECONFIG="$(pwd)/ignored/team-04.yaml"   # adjust to your team file

# Sanity
kubectl config current-context              # → hackathon-public
kubectl config view --minify -o jsonpath='{..namespace}'
                                            # → team-NN-restricted
kubectl version                             # server should be 1.34.x
kubectl auth can-i create pods              # → yes
kubectl get pods                            # smoke test, must not error

# Discover your dedicated HGX node (used by every check below)
TEAM_NODE=$(kubectl get pod -o jsonpath='{.items[0].spec.nodeName}')
echo "TEAM_NODE=${TEAM_NODE}"               # e.g. hgx076

# Discover your team number from the namespace prefix
TEAM_NN=$(kubectl config view --minify -o jsonpath='{..namespace}' \
          | sed -E 's/team-0*([0-9]+)-restricted/\1/' | xargs printf '%02d')
echo "TEAM_NN=${TEAM_NN}"                   # e.g. 04
```

> **Đã pass? [ ]**

---

## 1. Compute Access — ≥8 GPU dedicated

**Mục tiêu**: schedule 1 pod xin 8 GPU lên đúng HGX của đội.

> Note: if the pre-provisioned NIM (`llama-3-1-nemotron-nano-8b-v1`) is
> running and holding 1 GPU, this pod will stay `Pending` until you scale
> the NIM to 0 (`kubectl scale deploy/llama-3-1-nemotron-nano-8b-v1 --replicas=0`)
> or rerun against just 7 GPU.

```bash
TEAM_NODE=${TEAM_NODE} envsubst < manifests/02-gpu-eight.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/chk-02-gpu-eight --timeout=180s \
  || kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-02-gpu-eight --timeout=180s
kubectl logs chk-02-gpu-eight | tail -20
kubectl delete pod chk-02-gpu-eight --ignore-not-found
```

**Kết quả mong đợi**: `GPU_COUNT=8` and `CHECK_PASS: 8 GPU dedicated`.

> **Đã pass? [ ]**

---

## 2. GPU Type — H200 (Hopper)

**Mục tiêu**: `nvidia-smi -L` xác nhận GPU là **NVIDIA H200**.

```bash
TEAM_NODE=${TEAM_NODE} envsubst < manifests/01-gpu-smi.yaml | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-01-gpu-smi --timeout=120s
kubectl logs chk-01-gpu-smi
kubectl delete pod chk-01-gpu-smi --ignore-not-found
```

**Kết quả mong đợi**: `GPU 0: NVIDIA H200 ...` và `CHECK_PASS: H200 visible`.

> **Đã pass? [ ]**

---

## 3. Exclusive GPU per team — node isolation

**Mục tiêu**: pod đội không bị schedule lên HGX của đội khác.

The cluster enforces this via Kyverno + per-team `nodeSelector`. You can
verify your namespace is restricted to a single node with:

```bash
# All your pods must land on the same hgxNNN
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# Try scheduling without the team's nodeSelector (should be denied or
# auto-mutated by Kyverno to your own node):
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: chk-03-no-selector }
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: nvidia/cuda:12.4.0-base-ubuntu22.04
    command: ["bash","-lc","echo node=\${HOSTNAME}; sleep 1"]
    resources: { requests: { nvidia.com/gpu: "1" }, limits: { nvidia.com/gpu: "1" } }
    securityContext: { allowPrivilegeEscalation: false }
  securityContext:
    runAsUser: 1006
    runAsGroup: 1010
    runAsNonRoot: true
    fsGroup: 1010
EOF
kubectl get pod chk-03-no-selector -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl delete pod chk-03-no-selector --ignore-not-found
```

**Kết quả mong đợi**: pod lands on **your** `hgxNNN` only — never another team's.

> **Đã pass? [ ]**

---

## 4. Containers — Docker / Apptainer / Compose

**Mục tiêu**: cluster-side container runtime đầy đủ; verify bằng cách pull
một image NGC qua image-pull-secret `ngc-registry`.

```bash
kubectl get secret ngc-registry -o jsonpath='{.type}'   # → kubernetes.io/dockerconfigjson

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: chk-04-pull }
spec:
  restartPolicy: Never
  imagePullSecrets: [{ name: ngc-registry }]
  nodeSelector: { kubernetes.io/hostname: ${TEAM_NODE} }
  securityContext: { runAsUser: 1006, runAsGroup: 1010, runAsNonRoot: true, fsGroup: 1010 }
  containers:
  - name: c
    image: nvcr.io/nvidia/cuda:12.6.2-base-ubuntu22.04
    command: ["bash","-lc","echo PULL_OK; nvidia-smi -L | head -1"]
    resources: { requests: { nvidia.com/gpu: "1" }, limits: { nvidia.com/gpu: "1" } }
    securityContext: { allowPrivilegeEscalation: false }
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-04-pull --timeout=180s
kubectl logs chk-04-pull
kubectl delete pod chk-04-pull --ignore-not-found
```

**Kết quả mong đợi**: pod pulls + runs `PULL_OK`. Apptainer/Compose are
node-side runtimes available inside JupyterLab.

> **Đã pass? [ ]**

---

## 5. Kubernetes orchestration — version + namespace state

**Mục tiêu**: cluster là K8s ≥1.34 NVAIE-certified; namespace của đội tồn
tại với đầy đủ quyền pod/CRUD trong scope.

```bash
kubectl version | grep -E 'Server Version'        # v1.34.x
kubectl auth can-i --list 2>&1 | head -30          # capability matrix
kubectl get all                                    # current workloads
kubectl get resourcequota,limitrange               # may be empty
```

**Kết quả mong đợi**: Server `v1.34.*`; bạn `create/get/delete` được pod,
deployment, service, ingress trong namespace.

> **Đã pass? [ ]**

---

## 6. NGC + NIM API access — outbound HTTPS

**Mục tiêu**: pod gọi được `nvcr.io` và `build.nvidia.com`.

```bash
TEAM_NODE=${TEAM_NODE} envsubst < manifests/06-ngc-egress.yaml | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-06-ngc-egress --timeout=120s
kubectl logs chk-06-ngc-egress
kubectl delete pod chk-06-ngc-egress --ignore-not-found
```

**Kết quả mong đợi**: HTTP 200/401 từ `nvcr.io/v2/`, 200 từ `build.nvidia.com`,
plus `CHECK_PASS: NGC + NIM endpoints reachable`.

> **Đã pass? [ ]**

---

## 7. NCCL — NVLink + InfiniBand ≥80% peak

**Mục tiêu**: NCCL `all_reduce` busbw ≥80% NVLink theoretical.

```bash
TEAM_NODE=${TEAM_NODE} envsubst < manifests/03-nccl-allreduce.yaml | kubectl apply -f -
kubectl wait --for=condition=Complete job/chk-03-nccl --timeout=900s
POD=$(kubectl get pod -l chk=03-nccl -o name | head -1)
kubectl logs ${POD} | tail -40
kubectl delete -f manifests/03-nccl-allreduce.yaml --ignore-not-found
```

**Kết quả mong đợi**: `BUSBW_8G=…` ≥ 380 GB/s and `CHECK_PASS: NCCL busbw …`.

> **Đã pass? [ ]**

---

## 8. Multi-GPU Single Node (PyTorch / NeMo)

**Mục tiêu**: 8-GPU full-mesh NVLink reachable from a single PyTorch process.

The NCCL test in §7 already exercises 8-GPU NVLink. As a sanity:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: chk-08-torch }
spec:
  restartPolicy: Never
  imagePullSecrets: [{ name: ngc-registry }]
  nodeSelector: { kubernetes.io/hostname: NODE_PLACEHOLDER }
  securityContext: { runAsUser: 1006, runAsGroup: 1010, runAsNonRoot: true, fsGroup: 1010, supplementalGroups: [1009,1010] }
  containers:
  - name: t
    image: nvcr.io/nvidia/pytorch:24.10-py3
    command: ["python","-c","import torch; print('cuda_count', torch.cuda.device_count()); assert torch.cuda.device_count()==8"]
    resources: { requests: { nvidia.com/gpu: "8" }, limits: { nvidia.com/gpu: "8" } }
    securityContext: { allowPrivilegeEscalation: false }
EOF
# (replace NODE_PLACEHOLDER with $TEAM_NODE before applying, or use envsubst-style edit)
```

**Kết quả mong đợi**: `cuda_count 8`.

> **Đã pass? [ ]**

---

## 9. Multi-GPU Multi-Node — limitation note

Per the spec, **each team owns exactly 1 HGX node** (8 GPUs). Multi-node NCCL
across teams is **not** part of the team-scoped checklist — it is a
cluster-side capability validated by VTS at provisioning time. To verify the
node has IB / RDMA at all (the bedrock for multi-node):

```bash
kubectl exec -n $(kubectl config view --minify -o jsonpath='{..namespace}') \
  chk-01-gpu-smi -- bash -lc 'ls /dev/infiniband 2>/dev/null || echo NO_IB'
# (only useful while a chk pod is running; otherwise skip)
```

If your hackathon project genuinely needs ≥2 nodes, raise a ticket with the
on-site VTS support team — it is **not** auto-provisioned.

> **Đã pass? [ ]** (or N/A)

---

## 10. Ports policy — kubectl port-forward demo

**Mục tiêu**: expose service nội bộ qua `kubectl port-forward` trong port
range public 8000–8100.

```bash
TEAM_NODE=${TEAM_NODE} envsubst < manifests/07-portforward-demo.yaml | kubectl apply -f -
kubectl rollout status deploy/chk-07-demo --timeout=120s

# From your laptop, in a separate shell:
PORT=80${TEAM_NN}    # e.g. 8004 for team-04
kubectl port-forward --address 0.0.0.0 svc/chk-07-demo ${PORT}:80
# Then: curl -I http://localhost:${PORT}/   (or open in browser)
# Judges access externally:    https://login.h200.viettel.vn:${PORT}

# Cleanup
kubectl delete -f manifests/07-portforward-demo.yaml --ignore-not-found
```

**Kết quả mong đợi**: `200 OK` from nginx default page on `localhost:80NN`.

> **Đã pass? [ ]**

---

## 11. JupyterLab — wildcard subdomain over HTTPS

**Mục tiêu**: `https://team-NN.h200.viettel.vn` mở được JupyterLab; `*.team-NN`
hoạt động cho ứng dụng tự deploy.

```bash
# A. Browser: open https://team-${TEAM_NN}.h200.viettel.vn
#    → JupyterHub login, log in with the credentials shared with the team.

# B. Custom subdomain via Ingress. Re-use chk-07-demo from §10 and apply:
TEAM_NN=${TEAM_NN} INGRESS_CLASS=nginx \
  envsubst < manifests/08-ingress-demo.yaml | kubectl apply -f -
kubectl get ingress chk-08-ingress -o wide

# Then from anywhere on the public Internet:
curl -I https://chk08.team-${TEAM_NN}.h200.viettel.vn
```

**Kết quả mong đợi**: JupyterLab login renders; `curl` against the custom
subdomain returns `200 OK` (or `301` to HTTPS) backed by the nginx pod.

> **Đã pass? [ ]**

---

## 12. NVIDIA SDK pre-installed — image inventory

**Mục tiêu**: các image NeMo, TensorRT, TRT-LLM, Triton pull được từ NGC.

```bash
for IMG in \
  nvcr.io/nvidia/nemo:24.09 \
  nvcr.io/nvidia/tensorrt:24.10-py3 \
  nvcr.io/nvidia/tritonserver:24.10-py3 \
  nvcr.io/nvidia/tensorrt-llm/release:0.13.0
do
  echo "=== ${IMG} ==="
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: chk-12, labels: { chk: "12" } }
spec:
  restartPolicy: Never
  imagePullSecrets: [{ name: ngc-registry }]
  nodeSelector: { kubernetes.io/hostname: ${TEAM_NODE} }
  securityContext: { runAsUser: 1006, runAsGroup: 1010, runAsNonRoot: true, fsGroup: 1010 }
  containers:
  - name: c
    image: ${IMG}
    command: ["bash","-lc","echo ${IMG} OK"]
    securityContext: { allowPrivilegeEscalation: false }
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-12 --timeout=300s || kubectl describe pod chk-12 | tail -20
  kubectl logs chk-12 || true
  kubectl delete pod chk-12 --ignore-not-found
done
```

**Kết quả mong đợi**: cả 4 image pull được (có thể chậm lần đầu — NGC mirror
cluster-side đã pre-pull để giảm TTFB).

> **Đã pass? [ ]**

---

## 13. NVIDIA Nsight Profiling — nsys + ncu

**Mục tiêu**: `nsys` chạy được trong container và xuất ra report file.

```bash
TEAM_NODE=${TEAM_NODE} envsubst < manifests/09-nsight-profile.yaml | kubectl apply -f -
kubectl wait --for=condition=Complete job/chk-09-nsight --timeout=600s
POD=$(kubectl get pod -l chk=09-nsight -o name | head -1)
kubectl logs ${POD} | tail -20
kubectl delete -f manifests/09-nsight-profile.yaml --ignore-not-found
```

**Kết quả mong đợi**: `CHECK_PASS: nsys report N bytes` (N > 0).

> **Đã pass? [ ]**

---

## 14. Storage — 10 TiB GPFS, GDS, isolation

**Mục tiêu**: PVC dung lượng ~10 TiB tồn tại, đo được throughput, GDS bật.

```bash
# 14.a — confirm a 10 TiB-class PVC exists
kubectl get pvc

# Set PVC_NAME to the GPFS-backed PVC. If only `nemotron-nano-8b-cache`
# (200Gi local-path) shows up, your GPFS fileset PVC was not yet provisioned —
# raise a ticket with VTS support quoting your namespace.
export PVC_NAME=workspace            # adjust to actual name

# 14.b — fio sequential read/write
TEAM_NODE=${TEAM_NODE} PVC_NAME=${PVC_NAME} \
  envsubst < manifests/04-storage-io.yaml | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-04-storage-io --timeout=900s
kubectl logs chk-04-storage-io | tail -30
kubectl delete pod chk-04-storage-io --ignore-not-found

# 14.c — GPU Direct Storage
TEAM_NODE=${TEAM_NODE} PVC_NAME=${PVC_NAME} \
  envsubst < manifests/05-gds-check.yaml | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/chk-05-gds --timeout=300s
kubectl logs chk-05-gds | tail -40
kubectl delete pod chk-05-gds --ignore-not-found

# 14.d — cross-team deny test (negative): you should NOT be able to read
# another team's namespace.
kubectl get pvc -n team-01-restricted   # → Forbidden, expected
```

**Kết quả mong đợi**:
- a PVC of ≥10 TiB capacity is `Bound`,
- fio reports nontrivial MB/s for both read and write,
- gdscheck shows `GDS Operational Status: Enabled`,
- cross-namespace `get` is denied.

> **Đã pass? [ ]**

---

## 99. Dọn dẹp / Cleanup

```bash
kubectl delete -f manifests/ --ignore-not-found
kubectl get pod,job,svc,deploy,ingress -l app.kubernetes.io/part-of=servers-checklist
# Should print: No resources found ...
```

---

## Đối chiếu kết quả / Summary

| #  | Mục                                  | Section | Pass? |
|----|--------------------------------------|---------|-------|
| 1  | Compute Access (≥8 GPU/team)         | §1      | [ ]   |
| 2  | GPU Type (Hopper/Blackwell)          | §2      | [ ]   |
| 3  | Exclusive GPU per team               | §3      | [ ]   |
| 4  | Containers (Docker/Apptainer/Compose)| §4      | [ ]   |
| 5  | Kubernetes orchestration             | §5      | [ ]   |
| 6  | NGC + NIM API access                 | §6      | [ ]   |
| 7  | NCCL (NVLink + InfiniBand)           | §7      | [ ]   |
| 8  | Multi-GPU Single Node                | §8      | [ ]   |
| 9  | Multi-GPU Multi Node                 | §9      | [ ]   |
| 10 | Ports policy                         | §10     | [ ]   |
| 11 | JupyterLab port forwarding           | §11     | [ ]   |
| 12 | NVIDIA SDK pre-installed             | §12     | [ ]   |
| 13 | NVIDIA Nsight Profiling              | §13     | [ ]   |
| 14 | Storage isolation + bandwidth        | §14     | [ ]   |

If any row is blocked, ping the on-site VTS support — ticket should include:
team namespace, the `kubectl describe pod` of the failing check, and the last
20 lines of `kubectl logs`.
