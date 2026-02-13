#!/bin/bash
# start-bootc-vm.sh — Create a VM from a bootc container image hosted on GHCR
#
# Converts the bootc container image to a qcow2 disk using bootc-image-builder,
# then creates a libvirt VM from it. The bootc image already contains the admin
# user with empty-password SSH access (see Containerfile).
#
# Usage:
#   start-bootc-vm.sh [--delete] [--mode=full|slim] [--image=ghcr.io/owner/repo:tag] [vm-name]
#
# Modes:
#   full (default) — vllm-sr all-in-one: API + Dashboard + Grafana + Prometheus
#                     VM: 8GB RAM, 4 vCPUs, 100GB disk
#   slim           — extproc + Envoy sidecar: API only
#                     VM: 4GB RAM, 2 vCPUs, 40GB disk
#
# Examples:
#   start-bootc-vm.sh                          # full mode, auto-detect image
#   start-bootc-vm.sh --mode=slim my-vm
#   start-bootc-vm.sh --image=ghcr.io/org/hybrid-inference-in-a-box:main my-vm
#   start-bootc-vm.sh --delete my-vm
set -euo pipefail

ACTION="create"
VM_NAME=""
IMAGE=""
MODE="full"

# Parse arguments
for arg in "$@"; do
    case "${arg}" in
        --delete)
            ACTION="delete"
            ;;
        --mode=*)
            MODE="${arg#--mode=}"
            ;;
        --image=*)
            IMAGE="${arg#--image=}"
            ;;
        -*)
            echo "Usage: $0 [--delete] [--mode=full|slim] [--image=ghcr.io/owner/repo:tag] [vm-name]"
            exit 1
            ;;
        *)
            VM_NAME="${arg}"
            ;;
    esac
done

if [[ "${MODE}" != "full" && "${MODE}" != "slim" ]]; then
    echo "Error: Mode must be 'full' or 'slim', got '${MODE}'"
    exit 1
fi

# Mode-specific VM resources
if [[ "${MODE}" == "full" ]]; then
    RAM=8192
    VCPUS=4
    DISK_SIZE=100
else
    RAM=4096
    VCPUS=2
    DISK_SIZE=40
fi

VM_NAME="${VM_NAME:-bootc-vm-$(date +%Y%m%d%H%M%S)}"
VM_DIR="${BOOTC_VM_DIR:-${HOME}/bootc-vms}"
DISK_PATH="${VM_DIR}/${VM_NAME}.qcow2"
VM_USER="admin"
SSH_TIMEOUT=120

# Auto-detect image: try git remote first, fall back to ghcr.io package list
if [ -z "${IMAGE}" ]; then
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
    if [[ "${REMOTE_URL}" =~ github\.com[:/](.+)\.git$ ]] || \
       [[ "${REMOTE_URL}" =~ github\.com[:/](.+)$ ]]; then
        REPO="${BASH_REMATCH[1]}"
        IMAGE="ghcr.io/${REPO,,}:main"
    fi
fi

# If still empty, query the GHCR API for the latest tag
if [ -z "${IMAGE}" ]; then
    GHCR_REPO="redhat-et/hybrid-inference-in-a-box"
    TOKEN=$(curl -fSs "https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)
    if [ -n "${TOKEN}" ]; then
        LATEST_TAG=$(curl -fSs -H "Authorization: Bearer ${TOKEN}" \
            "https://ghcr.io/v2/${GHCR_REPO}/tags/list" 2>/dev/null \
            | python3 -c "import sys,json; tags=json.load(sys.stdin)['tags']; print('main' if 'main' in tags else tags[-1])" 2>/dev/null || true)
    fi
    if [ -n "${LATEST_TAG:-}" ]; then
        IMAGE="ghcr.io/${GHCR_REPO}:${LATEST_TAG}"
    else
        echo "ERROR: Cannot detect image from git remote or GHCR."
        echo "       Use --image=ghcr.io/owner/repo:tag"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Handle --delete: destroy and undefine the VM, then exit
# ─────────────────────────────────────────────────────────────────────────────
if [ "${ACTION}" = "delete" ]; then
    echo "STEP-01 Destroying VM '${VM_NAME}'..."
    sudo virsh destroy "${VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VM_NAME}" --remove-all-storage --nvram 2>/dev/null || true
    echo "STEP-02 VM '${VM_NAME}' has been removed."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build qcow2 from bootc container image
# ─────────────────────────────────────────────────────────────────────────────
OUTPUT_DIR="${VM_DIR}/${VM_NAME}-output"
mkdir -p "${OUTPUT_DIR}"

echo "STEP-01 Pulling ${IMAGE}..."
sudo podman pull "${IMAGE}"

echo "STEP-02 Building qcow2 from ${IMAGE}..."
sudo podman run \
    --rm \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${OUTPUT_DIR}":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    "${IMAGE}"

# Move qcow2 to final location and clean up build artifacts
sudo mv "${OUTPUT_DIR}/qcow2/disk.qcow2" "${DISK_PATH}"
sudo rm -rf "${OUTPUT_DIR}"

# Resize the disk — bootc images auto-grow the filesystem on first boot
echo "STEP-03 Resizing disk to ${DISK_SIZE}G..."
sudo qemu-img resize "${DISK_PATH}" "${DISK_SIZE}G"

# ─────────────────────────────────────────────────────────────────────────────
# Set deployment mode in the disk image before first boot
# ─────────────────────────────────────────────────────────────────────────────
# The image defaults to "full". If slim was requested, rewrite the kustomize
# entry point so MicroShift picks the correct overlay on its first start.
echo "STEP-04 Deployment mode: ${MODE}"
if [[ "${MODE}" == "slim" ]]; then
    echo "        Setting deployment mode to slim..."
    KUSTOMIZATION="apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - overlays/slim
"
    sudo virt-customize -a "${DISK_PATH}" \
        --write "/usr/lib/microshift/manifests.d/semantic-router/kustomization.yaml:${KUSTOMIZATION}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Create VM from the qcow2
# ─────────────────────────────────────────────────────────────────────────────
if sudo virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo "STEP-05 VM '${VM_NAME}' already exists. Skipping install."
    sudo virsh start "${VM_NAME}" 2>/dev/null || true
else
    echo "STEP-05 Removing stale VM definition if present..."
    sudo virsh destroy "${VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VM_NAME}" --remove-all-storage --nvram 2>/dev/null || true

    echo "STEP-05 Creating VM from bootc image..."
    sudo virt-install \
        --name "${VM_NAME}" \
        --ram "${RAM}" \
        --vcpus "${VCPUS}" \
        --disk "path=${DISK_PATH}" \
        --os-variant centos-stream10 \
        --network network=default \
        --graphics none \
        --import \
        --noautoconsole
fi

# ─────────────────────────────────────────────────────────────────────────────
# Wait for IP
# ─────────────────────────────────────────────────────────────────────────────
echo "STEP-06 Waiting for VM to get an IP address..."
IP=""
elapsed=0
while [ -z "${IP}" ] && [ "${elapsed}" -lt "${SSH_TIMEOUT}" ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    IP=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/ {split($4,a,"/"); print a[1]}')
done

if [ -z "${IP}" ]; then
    echo "ERROR: Could not get VM IP after ${SSH_TIMEOUT}s"
    echo "Try manually: sudo virsh domifaddr ${VM_NAME}"
    exit 1
fi

echo ""
echo "STEP-07 VM is ready!  (mode: ${MODE})"
echo "STEP-07 SSH command:"
echo ""
echo "    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${VM_USER}@${IP}"
echo ""
