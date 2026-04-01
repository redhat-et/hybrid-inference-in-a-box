#!/usr/bin/bash
# preload-models.sh - Pre-download semantic-router ML models during image build
#
# This script runs a temporary vllm-sr container to download all ML models
# (~18GB) so they don't need to be downloaded on first boot.

set -euo pipefail

CACHE_DIR="${1:-/var/cache/vllm-sr}"
CONTAINER_NAME="vllm-sr-preload-$$"

echo "Creating cache directory at ${CACHE_DIR}..."
mkdir -p "${CACHE_DIR}"

# Create a minimal config that will trigger model downloads
TEMP_CONFIG=$(mktemp)
cat > "${TEMP_CONFIG}" <<'EOF'
version: v0.3
listeners:
  - name: "api"
    address: "0.0.0.0"
    port: 8801
    timeout: "300s"
providers:
  defaults:
    default_model: "test-model"
  models:
    - name: "test-model"
      backend_refs:
        - name: "local"
          weight: 1
          endpoint: "localhost:8000"
          protocol: "http"
          api_key: "test"
routing:
  modelCards:
    - name: "test-model"
  signals:
    domains:
      - name: "other"
        description: "Test"
        mmlu_categories: ["other"]
  decisions:
    - name: "default"
      description: "Default"
      priority: 1
      rules:
        operator: "OR"
        conditions:
          - type: "domain"
            name: "other"
      modelRefs:
        - model: "test-model"
          use_reasoning: false
EOF

echo "Starting vllm-sr container to pre-download models..."
podman run --rm \
    --name "${CONTAINER_NAME}" \
    -v "${CACHE_DIR}":/root/.cache:Z \
    -v "${TEMP_CONFIG}":/tmp/config.yaml:ro,Z \
    --env VLLM_SR_RUNTIME_CONFIG_PATH=/tmp/config.yaml \
    ghcr.io/vllm-project/semantic-router/vllm-sr:latest \
    timeout 300 /app/start-router.sh /tmp/config.yaml /app/.vllm-sr || true

rm -f "${TEMP_CONFIG}"

# Verify models were downloaded
if [[ -d "${CACHE_DIR}/huggingface" ]]; then
    CACHE_SIZE=$(du -sh "${CACHE_DIR}" | cut -f1)
    echo "✓ Models cached successfully (${CACHE_SIZE})"
    echo "Cache contents:"
    ls -lh "${CACHE_DIR}"
else
    echo "⚠ Warning: Models may not have been fully cached"
fi
