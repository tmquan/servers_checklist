# servers_checklist

NVIDIA Open Hackathon 2026 — VTS H200 cluster onboarding checklist for newly
joining teams. Verifies the team's slice (1 HGX node, 8× H200, 10 TiB GPFS,
NGC/NIM, port-forward, ingress, Nsight) against the **NVIDIA Cluster Readiness
Checklist** (14 items) on page 7 of `ignored/NVIDIA Hackathon 2026 — Phương
án kỹ thuật cho VTS.pdf` (the source spec — kept under `ignored/` because it
is internal VTS material).

> Bilingual: Vietnamese headings, English commands and notes.

## Yêu cầu / Prerequisites

- `kubectl` ≥ 1.27 on PATH.
- `envsubst` (ships with GNU `gettext` — pre-installed on macOS via Homebrew
  `brew install gettext`, on Ubuntu via `apt install gettext-base`).
- The team's kubeconfig file from the organizers, e.g. `team-04.yaml`. Place
  it under `ignored/` (the directory is git-ignored, so the bearer token will
  never be committed).

## Quick start — chạy validator một lần / one-shot validator

```bash
# 1. Drop the kubeconfig the organizers gave you into ignored/team-NN.yaml.
# 2. Run the validator:
./check.sh ignored/team-04.yaml

# Optional flags
./check.sh ignored/team-04.yaml --skip 03,04        # skip slow steps (NCCL, fio)
./check.sh ignored/team-04.yaml --only 01,02,06     # quick smoke
./check.sh ignored/team-04.yaml --pvc workspace     # override PVC name
./check.sh ignored/team-04.yaml --no-cleanup        # keep resources for debugging
```

You'll see colored `[ PASS ]` / `[ FAIL ]` / `[ WARN ]` / `[ SKIP ]` lines as
each check runs, then a final 14-row summary aligned with the readiness
checklist. The script applies manifests from `manifests/`, waits, scrapes
sentinel strings from logs, and tears everything down on exit.

Exit codes: `0` if no failures; `1` if any check failed.

## Hướng dẫn từng bước / Manual walkthrough

If you prefer to run the 14 readiness items by hand, see
[`CHECKLIST.md`](CHECKLIST.md). It is bilingual, copy-pasteable, and includes
expected output and troubleshooting hints per section.

## Repo layout

```
.
├── README.md              # this file
├── CHECKLIST.md           # 14-item bilingual runbook
├── check.sh               # one-shot validator
├── ignored/               # git-ignored — drop your kubeconfig + the VTS PDF here
│   ├── team-NN.yaml             # your team's kubeconfig (NEVER commit)
│   └── NVIDIA Hackathon 2026 — Phương án kỹ thuật cho VTS.pdf
└── manifests/             # k8s YAMLs referenced by both flows
    ├── 01-gpu-smi.yaml          # nvidia-smi 1× GPU         (item #2)
    ├── 02-gpu-eight.yaml        # 8× GPU schedulability     (items #1, #3, #8)
    ├── 03-nccl-allreduce.yaml   # NCCL all_reduce 8 GPU     (item #7)
    ├── 04-storage-io.yaml       # fio 10 GiB seq r/w        (item #14)
    ├── 05-gds-check.yaml        # GPU Direct Storage probe  (item #14)
    ├── 06-ngc-egress.yaml       # nvcr.io / build.nvidia.com (item #6)
    ├── 07-portforward-demo.yaml # nginx for port-forward    (item #10)
    ├── 08-ingress-demo.yaml     # wildcard subdomain        (item #11)
    └── 09-nsight-profile.yaml   # nsys profile sample       (item #13)
```

Manifests use the placeholders `${TEAM_NODE}`, `${TEAM_NN}`, `${PVC_NAME}`,
`${INGRESS_CLASS}`. `check.sh` resolves them automatically from your
kubeconfig + cluster state. If you apply a manifest by hand, run it through
`envsubst` first:

```bash
TEAM_NODE=hgx076 TEAM_NN=04 INGRESS_CLASS=nginx \
  envsubst < manifests/01-gpu-smi.yaml | kubectl apply -f -
```

## Lưu ý quan trọng / Important notes

- **NIM holding 1 GPU**: if the pre-provisioned `llama-3-1-nemotron-nano-8b-v1`
  Deployment is running, item #1 (8 GPU) will fail because 1 GPU is taken.
  Scale it to 0 (`kubectl scale deploy/llama-3-1-nemotron-nano-8b-v1 --replicas=0`)
  before running step 02, then scale back if you want to keep using it.
- **GPFS PVC**: the 10 TiB IBM Storage Scale fileset is provisioned per team
  by VTS. If `kubectl get pvc` only shows the small NIM cache PVC, raise a
  ticket with the on-site VTS support team before running step 04.
- **Ingress class**: the manifest defaults to `nginx`. Set
  `INGRESS_CLASS=traefik` (or whatever the cluster uses) before running if
  needed.
- **Cross-team isolation**: `check.sh` issues a deliberate `kubectl get pvc -n
  team-01-restricted` to confirm RBAC denies cross-namespace reads — that
  `Forbidden` you'll see in the logs is the **expected** outcome.

## Troubleshooting

When a check fails, the summary line shows a one-line hint. For details:

```bash
kubectl describe pod <chk-NN-...>
kubectl logs <chk-NN-...> --previous
kubectl get events --sort-by=.lastTimestamp | tail -20
```

If you remain stuck, ping the on-site VTS support with: team namespace, the
failing manifest, last 20 lines of pod logs, and `kubectl describe pod` output.
