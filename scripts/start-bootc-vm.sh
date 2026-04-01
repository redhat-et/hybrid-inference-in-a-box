#!/bin/bash
# start-bootc-vm.sh — Create a VM from a bootc container image hosted on GHCR
#
# Converts the bootc container image to a qcow2 disk using bootc-image-builder,
# then creates a libvirt VM from it. The bootc image already contains the admin
# user with empty-password SSH access (see Containerfile).
#
# Usage:
#   start-bootc-vm.sh [--delete] [--image=ghcr.io/owner/repo:tag] [vm-name]
#
# Examples:
#   start-bootc-vm.sh                          # auto-detect image from git remote
#   start-bootc-vm.sh --image=ghcr.io/org/hybrid-inference-in-a-box:main my-vm
#   start-bootc-vm.sh --delete my-vm
set -euo pipefail

ACTION="create"
VM_NAME=""
IMAGE=""

# Parse arguments
for arg in "$@"; do
    case "${arg}" in
        --delete)
            ACTION="delete"
            ;;
        --image=*)
            IMAGE="${arg#--image=}"
            ;;
        -*)
            echo "Usage: $0 [--delete] [--image=ghcr.io/owner/repo:tag] [vm-name]"
            exit 1
            ;;
        *)
            VM_NAME="${arg}"
            ;;
    esac
done

RAM=16384
VCPUS=8
DISK_SIZE=100

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
mkdir -p "${VM_DIR}/bib-tmp"

if [[ "${IMAGE}" == localhost/* ]]; then
    echo "STEP-01 Using local image ${IMAGE}..."

    # Reset rootful podman storage to clear all stale locks/containers/volumes
    echo "STEP-01 Resetting rootful podman storage..."
    sudo podman system reset -f 2>/dev/null || true

    # Transfer the image from rootless to rootful storage
    echo "STEP-01 Transferring ${IMAGE} to rootful podman storage..."
    podman save "${IMAGE}" | sudo podman load

    # Verify the image is now accessible
    if ! sudo podman image inspect "${IMAGE}" --format '{{.Id}}' >/dev/null 2>&1; then
        echo "ERROR: Failed to transfer ${IMAGE} to rootful storage"
        exit 1
    fi
    echo "STEP-01 Image verified in rootful storage."
else
    echo "STEP-01 Pulling ${IMAGE}..."
    sudo podman pull "${IMAGE}"
fi

echo "STEP-02 Building qcow2 from ${IMAGE}..."
sudo podman run \
    --rm \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${OUTPUT_DIR}":/output \
    -v "${VM_DIR}/bib-tmp":/var/tmp \
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
# Create VM from the qcow2
# ─────────────────────────────────────────────────────────────────────────────
if sudo virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo "STEP-04 VM '${VM_NAME}' already exists. Skipping install."
    sudo virsh start "${VM_NAME}" 2>/dev/null || true
else
    echo "STEP-04 Removing stale VM definition if present..."
    sudo virsh destroy "${VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VM_NAME}" --remove-all-storage --nvram 2>/dev/null || true

    echo "STEP-04 Creating VM from bootc image..."
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
echo "STEP-05 Waiting for VM to get an IP address..."
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
echo "STEP-06 VM is ready!"
echo "STEP-06 SSH command:"
echo ""
echo "    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${VM_USER}@${IP}"
echo ""
echo "STEP-06 Endpoints (once MicroShift is running):"
echo "    API:       http://${IP}:30801/v1/chat/completions"
echo "    Dashboard: http://${IP}:30700"
echo "    Grafana:   http://${IP}:30300"
echo ""
