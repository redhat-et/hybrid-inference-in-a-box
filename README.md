# Hybrid Inference in a Box — bootc Image

An immutable, self-contained appliance that boots MicroShift with the vLLM
Semantic Router and an optional local Small Language Model (SLM). Simpler
queries run on-device via the local GPU; complex queries route to external
LLM endpoints — all through a single OpenAI-compatible API.

## Architecture

```
bootc image (CentOS Stream 10)
├── MicroShift (RPM, auto-starts on boot)
├── manifests.d/semantic-router/    ← semantic router
├── manifests.d/vllm-slm/          ← local SLM (GPU builds only)
├── Pre-pulled container images
├── NVIDIA Container Toolkit + CDI  ← GPU runtime (GPU builds only)
├── GPU Operator (Helm, post-boot)  ← device plugin (GPU builds only)
├── /usr/local/bin/setup-gpu-operator.sh
├── /usr/local/bin/configure-semantic-router.sh
└── /etc/semantic-router/templates/

┌──────────────────────────────┐     ┌──────────────────────────────┐
│  semantic-router namespace   │     │  vllm-slm namespace          │
│  ┌────────────────────────┐  │     │  ┌────────────────────────┐  │
│  │ semantic-router Deploy │  │     │  │ vllm-slm Deployment    │  │
│  │ (vllm-sr all-in-one)   │  │     │  │ └─ vLLM container      │  │
│  │ API + Dashboard +      │  │     │  │    Qwen2.5-1.5B        │  │
│  │ Grafana + Prometheus   │  │     │  │    port 8000 (OpenAI)  │  │
│  └────────────────────────┘  │     │  │    NVIDIA GPU           │  │
│  NodePort 30801 (API)        │     │  └────────────────────────┘  │
│  NodePort 30700 (Dashboard)  │     │  NodePort 30500 (direct API) │
│  NodePort 30300 (Grafana)    │     └──────────────────────────────┘
└──────────────────────────────┘
         │
         ├───► External LLM (e.g. litellm.example.com, HTTPS)
         └───► Local SLM (vllm-slm.vllm-slm.svc:8000, HTTP)
```

**Boot flow:**
1. MicroShift starts → applies manifests → pods wait for config
2. *(GPU builds only)* User runs `setup-gpu-operator.sh` → GPU becomes available → SLM pod starts
3. User runs `configure-semantic-router.sh` → creates ConfigMap + Secret → router starts

## Components

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **Semantic Router** | `semantic-router` | Routes queries to the right model based on domain classification |
| **vLLM SLM** *(GPU only)* | `vllm-slm` | Local Qwen2.5-1.5B-Instruct served by vLLM on GPU |
| **GPU Operator** *(GPU only)* | `gpu-operator` | NVIDIA device plugin + GPU feature discovery (Helm) |

## Build

**With GPU support** (default — requires NVIDIA container toolkit repo):

```bash
podman build -t hybrid-inference-bootc:latest -f Containerfile .
```

**Without GPU** (external endpoints only — no NVIDIA dependencies):

```bash
podman build --build-arg ENABLE_GPU=false -t hybrid-inference-bootc:latest -f Containerfile .
```

The `ENABLE_GPU=false` build skips the NVIDIA container toolkit, local SLM
manifests, vLLM image pre-pull, and Helm. The resulting image builds on any
host without NVIDIA repos.

**ML Model Pre-loading:** The image build pre-downloads semantic-router ML
models (~18GB including jailbreak detection, PII detection, and domain
classification models) to eliminate first-boot download delays. This increases
the final image size to ~24GB but ensures VMs boot with fully operational
semantic routing immediately.

CI builds run automatically on push to `main` and publish multi-arch
(amd64 + arm64) manifest lists to
`ghcr.io/<owner>/hybrid-inference-in-a-box:<tag>`. See
[`.github/workflows/build-bootc.yaml`](.github/workflows/build-bootc.yaml).

## First Boot

> [!NOTE]
> On first boot, infrastructure pods may briefly show `CreateContainerConfigError`
> (waiting for ConfigMap/Secret). If built with GPU support, the vLLM SLM
> pod will show `Pending` (waiting for GPU resources). semantic-router pods
> start immediately since ML models are pre-loaded during image build.

### 1. Boot the image

Deploy via VM (qcow2), bare metal (ISO), or cloud (AMI). MicroShift starts
automatically.

**Quick start with KVM/libvirt:**

```bash
./scripts/start-bootc-vm.sh
```

### 2. Set up GPU support (GPU builds only)

The GPU Operator installs the NVIDIA device plugin and GPU feature discovery.
This is required for the SLM pod to access the GPU.

```bash
sudo setup-gpu-operator.sh
```

This script:
- Configures CRI-O with the NVIDIA container runtime
- Generates CDI specs for GPU device injection
- Grants OpenShift SCCs to GPU Operator service accounts
- Installs the GPU Operator via Helm (driver + toolkit disabled, uses host drivers)
- Waits for `nvidia.com/gpu` to be advertised

### 3. Wait for the SLM to start (GPU builds only)

Once the GPU is available, the vLLM SLM pod downloads the model from
HuggingFace and starts serving. First boot takes a few minutes for the
download.

```bash
sudo kubectl -n vllm-slm get pods -w
# Wait for READY 1/1

# Verify the model is serving
curl http://<IP>:30500/v1/models
```

### 4. Configure the semantic router

Copy the example config and edit it:

```bash
cp config/router.yaml.example router.yaml
vi router.yaml   # edit endpoints, API keys, models
sudo configure-semantic-router.sh router.yaml
```

**External endpoints only** (no GPU / no local SLM):

```yaml
providers:
  defaults:
    default_model: "Mistral-Small-24B-W8A8"
  models:
    - name: "Mistral-Small-24B-W8A8"
      backend_refs:
        - name: "litellm"
          weight: 1
          endpoint: "litellm.example.com:443"
          protocol: "https"
          api_key: "sk-your-key-here"
```

**Hybrid** (local SLM + external LLMs — requires GPU build):

```yaml
providers:
  defaults:
    default_model: "Qwen2.5-1.5B-Instruct"
  models:
    - name: "Mistral-Small-24B-W8A8"
      backend_refs:
        - name: "litellm"
          weight: 1
          endpoint: "litellm.example.com:443"
          protocol: "https"
          api_key: "sk-your-key-here"

    - name: "Qwen2.5-1.5B-Instruct"
      backend_refs:
        - name: "local-vllm"
          weight: 1
          endpoint: "vllm-slm.vllm-slm.svc:8000"
          protocol: "http"
```

### 5. Wait for router pods

```bash
sudo kubectl -n semantic-router get pods -w
```

First boot downloads ~18GB of classifier models.

### 6. Access

| Endpoint | URL |
|----------|-----|
| Router API | `http://<IP>:30801/v1/chat/completions` |
| SLM direct *(GPU only)* | `http://<IP>:30500/v1/chat/completions` |
| Dashboard | `http://<IP>:30700` |
| Grafana | `http://<IP>:30300` |

### 7. Test

```bash
# Query via router
curl -s http://<IP>:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is photosynthesis?"}]}' | jq .

# Direct SLM access (GPU builds only, bypass router)
curl -s http://<IP>:30500/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"What is 2+2?"}]}' | jq .
```

## GPU Support

### Prerequisites

The host must have:
- NVIDIA GPU with drivers pre-installed
- `nvidia-container-toolkit` package (baked into GPU builds of the bootc image)

### DGX Spark / GB10

The NVIDIA GB10 (Blackwell, CUDA capability 12.1) has unified memory shared
with the CPU. The vLLM deployment accounts for this:

- `--gpu-memory-utilization 0.5` — only uses 50% of reported GPU memory
  (the rest is shared with the system)
- `--enforce-eager` — disables Triton/torch.compile (the bundled ptxas
  doesn't support `sm_121a` yet)

### Boot-time automation

The `generate-nvidia-cdi.sh` systemd service runs on every boot before
MicroShift and:
1. Configures CRI-O with the NVIDIA container runtime (`nvidia-ctk runtime configure`)
2. Generates CDI specs at `/etc/cdi/nvidia.yaml`

## Reconfiguring

Edit `router.yaml` and re-run `configure-semantic-router.sh`:

```bash
sudo configure-semantic-router.sh router.yaml
```

## What's Baked vs Runtime

| Baked in image (immutable) | Configured post-boot |
|---|---|
| Namespace, Deployments, Services | Model names (`router.yaml`) |
| Prometheus + Grafana | LLM endpoint(s) and API key(s) |
| vLLM SLM deployment + image *(GPU only)* | Default model |
| NVIDIA Container Toolkit + CDI *(GPU only)* | GPU Operator (Helm, `setup-gpu-operator.sh`) |
| Helm binary *(GPU only)* | |
| Container images (pre-pulled) | |
| Firewall rules, systemd units | |
| Config templates | |

## File Layout

```
hybrid-inference-in-a-box/
├── Containerfile
├── .github/workflows/
│   └── build-bootc.yaml              ← CI/CD: build & push to GHCR
├── manifests/
│   ├── semantic-router/
│   │   ├── kustomization.yaml
│   │   ├── base/
│   │   │   ├── kustomization.yaml
│   │   │   └── namespace.yaml
│   │   └── overlays/
│   │       └── full/                  ← vllm-sr + grafana + prometheus
│   └── vllm-slm/
│       ├── kustomization.yaml
│       └── base/
│           ├── kustomization.yaml
│           ├── namespace.yaml
│           ├── deployment.yaml        ← vLLM + Qwen2.5-1.5B on GPU
│           └── service.yaml           ← NodePort 30500
├── config/
│   ├── router.yaml.example           ← sample config (external + local models)
│   ├── llm-router-dashboard.json
│   └── templates/
│       └── config.yaml.tmpl
├── scripts/
│   ├── configure-semantic-router.sh   ← post-boot router configuration
│   ├── setup-gpu-operator.sh          ← install NVIDIA GPU Operator (Helm)
│   ├── generate-nvidia-cdi.sh         ← CRI-O runtime + CDI specs (systemd)
│   ├── start-bootc-vm.sh             ← create VM from bootc image
│   ├── create-vg.sh                   ← loopback LVM VG for TopoLVM
│   └── make-rshared.service
└── README.md
```

## Troubleshooting

**Pods stuck in CreateContainerConfigError:**
Run `configure-semantic-router.sh` — the pods are waiting for ConfigMap/Secret.

**vLLM SLM pod stuck in Pending:**
The GPU Operator hasn't advertised `nvidia.com/gpu` yet. Run
`setup-gpu-operator.sh` and check:
```bash
sudo kubectl get nodes -o jsonpath='{.items[0].status.allocatable}' | python3 -m json.tool | grep nvidia
```

**vLLM SLM crashes with "Free memory ... less than desired":**
The default `--gpu-memory-utilization` is too high for unified memory GPUs.
Edit the deployment:
```bash
sudo kubectl -n vllm-slm edit deployment vllm-slm
# Lower --gpu-memory-utilization (default: 0.5, try 0.3)
```

**vLLM crashes with "ptxas fatal: Value 'sm_121a' is not defined":**
The GPU architecture is too new for the bundled Triton. The deployment
includes `--enforce-eager` to work around this. If you removed it, add it
back.

**GPU Operator pods stuck (SCC errors):**
The `setup-gpu-operator.sh` script grants SCCs automatically. If you
installed manually, grant them:
```bash
oc adm policy add-scc-to-user privileged -n gpu-operator -z node-feature-discovery
oc adm policy add-scc-to-user privileged -n gpu-operator -z nvidia-device-plugin
# ... (see setup-gpu-operator.sh for the full list)
```

**TopoLVM pods in CrashLoopBackOff:**
```bash
sudo systemctl status create-vg
sudo vgs myvg1
```

**MicroShift not starting:**
```bash
sudo systemctl status microshift
sudo journalctl -u microshift --no-pager -l
```

**Router not connecting to LLM endpoint:**
```bash
curl -s https://<endpoint>/models -H 'Authorization: Bearer <key>'
```
