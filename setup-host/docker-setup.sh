#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo $0 install|uninstall)" >&2
    exit 1
fi

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name <command>

Commands:
  install     Install Docker CE on Ubuntu 24.04
  uninstall   Completely remove Docker and all its data

Examples:
  sudo $base_name install
  sudo $base_name uninstall
EOF
    exit 0
}

do_install() {
    echo "── Removing old Docker packages (if any) ──"
    apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 \
        podman-docker containerd runc 2>/dev/null || true

    echo ""
    echo "── Installing prerequisites ──"
    apt-get update
    apt-get install -y ca-certificates curl

    echo ""
    echo "── Adding Docker GPG key ──"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo ""
    echo "── Adding Docker repository ──"
    # shellcheck disable=SC1091
    tee /etc/apt/sources.list.d/docker.sources <<REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
REPO

    echo ""
    echo "── Installing Docker ──"
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    echo ""
    echo "── Enabling and starting Docker ──"
    # Swapping a preinstalled docker.io (some VPS images ship it) for docker-ce
    # can leave docker.socket failed, or still "active" from docker.io but with
    # no listening fd ("socket unit configuration has changed while unit has been
    # running"); dockerd -H fd:// then exits with "no sockets found via socket
    # activation". 'enable --now' is a no-op on an active unit, so stop both
    # units and start the socket before the service.
    systemctl daemon-reload
    systemctl stop docker.service docker.socket 2>/dev/null || true
    systemctl reset-failed docker.socket docker.service 2>/dev/null || true
    systemctl enable docker.socket docker
    systemctl start docker.socket
    systemctl start docker

    echo ""
    echo "── Adding current sudo user to docker group ──"
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        echo "User '$SUDO_USER' added to docker group (re-login to take effect)."
    fi

    echo ""
    echo "── Verifying installation ──"
    docker version --format 'Docker {{.Server.Version}}'
    docker compose version

    echo ""
    echo "Done. Docker is installed and running."
}

do_uninstall() {
    echo "This will completely remove Docker, all containers, images, and volumes."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "── Stopping all running containers ──"
    if command -v docker &>/dev/null; then
        docker ps -q | xargs -r docker stop 2>/dev/null || true
    fi

    echo ""
    echo "── Removing Docker packages ──"
    apt-get purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get autoremove -y

    echo ""
    echo "── Removing Docker data ──"
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd

    echo ""
    echo "── Removing Docker repository and GPG key ──"
    rm -f /etc/apt/sources.list.d/docker.sources
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.asc

    echo ""
    echo "── Removing docker group ──"
    if getent group docker &>/dev/null; then
        groupdel docker 2>/dev/null || true
    fi

    echo ""
    echo "Done. Docker has been completely removed."
}

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         usage ;;
esac