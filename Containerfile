ARG MICROSHIFT_VERSION=4.21.0_g29f429c21_4.21.0_okd_scos.ec.15
FROM ghcr.io/microshift-io/microshift:${MICROSHIFT_VERSION}

LABEL org.opencontainers.image.title="hybrid-inference-in-a-box" \
      org.opencontainers.image.description="Immutable bootc appliance: MicroShift + vLLM Semantic Router" \
      org.opencontainers.image.source="https://github.com/redhat-et/hybrid-inference-in-a-box" \
      org.opencontainers.image.vendor="Red Hat" \
      org.opencontainers.image.base.name="ghcr.io/microshift-io/microshift:${MICROSHIFT_VERSION}"

# ─────────────────────────────────────────────────────────────────────────────
# Firewall rules
# ─────────────────────────────────────────────────────────────────────────────
# SSH access
RUN firewall-offline-cmd --add-service=ssh && \
    firewall-offline-cmd --add-service=http && \
    firewall-offline-cmd --add-service=https && \
    # NodePort range for Kubernetes services
    firewall-offline-cmd --add-port=30000-32767/tcp && \
    firewall-offline-cmd --add-port=30000-32767/udp && \
    # Pod and service network CIDRs (trusted for internal cluster traffic)
    firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16 && \
    firewall-offline-cmd --zone=trusted --add-source=169.254.169.1

# ─────────────────────────────────────────────────────────────────────────────
# Systemd services
# ─────────────────────────────────────────────────────────────────────────────
# OVN-Kubernetes requires rshared mount propagation on the root filesystem
COPY scripts/make-rshared.service /etc/systemd/system/

# ─────────────────────────────────────────────────────────────────────────────
# TopoLVM storage — create a loopback-backed LVM volume group on first boot
# ─────────────────────────────────────────────────────────────────────────────
# MicroShift's TopoLVM CSI driver expects a volume group named "myvg1".
# Since bootc images don't have a dedicated LVM partition, we create a
# sparse loopback file and attach it as a PV on every boot (before MicroShift
# starts). The file is only allocated on first boot; subsequent boots reuse it.
COPY scripts/create-vg.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/create-vg.sh && \
    printf '[Unit]\nDescription=Create loopback LVM VG for TopoLVM\nBefore=microshift.service\nAfter=local-fs.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/create-vg.sh\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' \
      > /etc/systemd/system/create-vg.service

RUN systemctl enable firewalld microshift make-rshared create-vg

# ─────────────────────────────────────────────────────────────────────────────
# Kustomize manifests — infrastructure only, no configuration baked in
# ─────────────────────────────────────────────────────────────────────────────
# MicroShift auto-applies kustomizations from /usr/lib/microshift/manifests.d/*/
# on boot. These define the Deployments, Services, etc. but reference ConfigMaps
# and Secrets that don't exist yet — pods will wait until
# configure-semantic-router.sh creates them post-boot.
COPY manifests/semantic-router/ /usr/lib/microshift/manifests.d/semantic-router/

# ─────────────────────────────────────────────────────────────────────────────
# Configuration templates + helper scripts
# ─────────────────────────────────────────────────────────────────────────────
COPY config/templates/ /etc/semantic-router/templates/
COPY config/llm-router-dashboard.json /etc/semantic-router/
COPY scripts/configure-semantic-router.sh /usr/local/bin/
COPY scripts/select-mode.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/configure-semantic-router.sh /usr/local/bin/select-mode.sh

# ─────────────────────────────────────────────────────────────────────────────
# Default user — passwordless SSH for quick access to the appliance
# ─────────────────────────────────────────────────────────────────────────────
RUN useradd -M -d /var/home/admin -G wheel admin && \
    passwd -d admin && \
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel-nopasswd && \
    chmod 440 /etc/sudoers.d/wheel-nopasswd && \
    echo "d /var/home/admin 0700 admin admin -" > /etc/tmpfiles.d/admin-home.conf && \
    sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# ─────────────────────────────────────────────────────────────────────────────
# Pre-pull container images for air-gapped operation
# ─────────────────────────────────────────────────────────────────────────────
# Images are saved to dir: format at build time (no user-namespace needed),
# then copied into CRI-O's containers-storage at boot via a systemd
# ExecStartPre hook — the same pattern used by upstream MicroShift.
RUN cp /etc/subuid /etc/subuid.bak 2>/dev/null || true && \
    cp /etc/subgid /etc/subgid.bak 2>/dev/null || true && \
    echo "root:100000:65536" > /etc/subuid && \
    echo "root:100000:65536" > /etc/subgid && \
    IMAGES=" \
      ghcr.io/vllm-project/semantic-router/vllm-sr:latest \
      ghcr.io/vllm-project/semantic-router/extproc:latest \
      docker.io/envoyproxy/envoy:v1.31.7 \
      docker.io/prom/prometheus:v2.53.3 \
      docker.io/grafana/grafana:11.4.0" && \
    mkdir -p /usr/lib/containers/storage && \
    for img in ${IMAGES}; do \
      sha="$(echo "${img}" | sha256sum | awk '{print $1}')" && \
      skopeo copy --preserve-digests \
        "docker://${img}" "dir:/usr/lib/containers/storage/${sha}" && \
      echo "${img},${sha}" >> /usr/lib/containers/storage/image-list.txt ; \
    done && \
    if [ -f /etc/subuid.bak ]; then mv /etc/subuid.bak /etc/subuid; fi && \
    if [ -f /etc/subgid.bak ]; then mv /etc/subgid.bak /etc/subgid; fi

# Install a systemd hook that copies the embedded images into CRI-O storage
# on first boot, before MicroShift starts pulling pods.
RUN printf '#!/bin/bash\nset -euo pipefail\n\
IMG_LIST=/usr/lib/containers/storage/image-list.txt\n\
[ -f "$IMG_LIST" ] || exit 0\n\
while IFS="," read -r img sha; do\n\
  skopeo copy --preserve-digests \\\n\
    "dir:/usr/lib/containers/storage/${sha}" \\\n\
    "containers-storage:${img}"\n\
done < "$IMG_LIST"\n' > /usr/local/bin/embed-images.sh && \
    chmod +x /usr/local/bin/embed-images.sh && \
    mkdir -p /etc/systemd/system/microshift.service.d && \
    printf '[Service]\nExecStartPre=/usr/local/bin/embed-images.sh\n' \
      > /etc/systemd/system/microshift.service.d/embed-images.conf
