#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo $0 install|status|uninstall)" >&2
    exit 1
fi

# sshd drop-in; sorts before Ubuntu's 50-cloud-init.conf, and in sshd_config
# the FIRST definition of an option wins, so this file takes precedence.
DROPIN=/etc/ssh/sshd_config.d/10-shallow-tuna.conf
# Only used on releases with socket activation but without Ubuntu's
# sshd-socket-generator (24.04+ regenerate ssh.socket from sshd_config).
SOCKET_DROPIN=/etc/systemd/system/ssh.socket.d/10-shallow-tuna.conf

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name <command>

Commands:
  install [port]   Write $DROPIN (port, listen on all
                   addresses, root login allowed, key auth only), validate and
                   restart sshd. Port defaults to the current one.
  status           Show the effective port, listen sockets and the drop-in
  uninstall        Remove the drop-in and restart sshd

Examples:
  sudo $base_name install          # keep the port, apply the options
  sudo $base_name install 2222     # move sshd to 2222
  sudo $base_name status
EOF
    exit 0
}

current_port() {
    sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'
}

socket_activated() {
    systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1
}

# Refuse to turn off password auth when nobody could log in with a key.
require_authorized_key() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -s "$f" ]] && return 0
    done
    echo "Error: no non-empty authorized_keys found (root or /home/*)." >&2
    echo "       Install a public key first, or you will be locked out." >&2
    exit 1
}

restart_sshd() {
    local port="$1"
    echo "── Validating sshd config ──"
    sshd -t

    echo ""
    echo "── Restarting sshd ──"
    systemctl daemon-reload
    if socket_activated; then
        systemctl restart ssh.socket
        if ! systemctl show -p Listen ssh.socket | grep -q ":${port} "; then
            echo "ssh.socket does not listen on $port (no sshd-socket-generator?) — adding a socket drop-in"
            mkdir -p "$(dirname "$SOCKET_DROPIN")"
            cat > "$SOCKET_DROPIN" <<SOCK
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
SOCK
            systemctl daemon-reload
            systemctl restart ssh.socket
        fi
    else
        systemctl restart ssh
    fi

    echo ""
    echo "── Verifying ──"
    echo "  sshd port:  $(current_port)"
    if socket_activated; then
        echo "  ssh.socket: $(systemctl show -p Listen ssh.socket | sed 's/^Listen=//' | tr '\n' ' ')"
    fi
}

do_install() {
    local port="${1:-}"
    [[ -z "$port" ]] && port="$(current_port)"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
        || { echo "Error: invalid port '$port'" >&2; exit 1; }

    require_authorized_key

    echo "── Writing $DROPIN ──"
    cat > "$DROPIN" <<CONF
Port ${port}
ListenAddress 0.0.0.0
ListenAddress ::
PermitRootLogin yes
PasswordAuthentication no
CONF
    chmod 644 "$DROPIN"
    sed 's/^/  /' "$DROPIN"

    echo ""
    restart_sshd "$port"

    echo ""
    echo "Done. sshd listens on port $port, key authentication only."
    echo "Keep this session open and test a new login before closing it."
}

do_status() {
    echo "── Effective sshd settings ──"
    sshd -T 2>/dev/null | grep -E '^(port|listenaddress|passwordauthentication|permitrootlogin|pubkeyauthentication) ' | sed 's/^/  /'
    echo ""
    echo "── Activation ──"
    if socket_activated; then
        echo "  socket-activated: $(systemctl show -p Listen ssh.socket | sed 's/^Listen=//' | tr '\n' ' ')"
    else
        echo "  ssh.service only (no socket activation)"
    fi
    [[ -x /usr/lib/systemd/system-generators/sshd-socket-generator ]] \
        && echo "  sshd-socket-generator: present (ssh.socket follows sshd_config)" \
        || echo "  sshd-socket-generator: absent"
    echo ""
    echo "── Drop-ins ──"
    [[ -f "$DROPIN" ]] && { echo "  $DROPIN:"; sed 's/^/    /' "$DROPIN"; } || echo "  $DROPIN: absent"
    [[ -f "$SOCKET_DROPIN" ]] && echo "  $SOCKET_DROPIN: present" || true
}

do_uninstall() {
    echo "This removes $DROPIN (sshd falls back to the distro defaults, port 22)."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi
    rm -f "$DROPIN" "$SOCKET_DROPIN"
    echo ""
    restart_sshd "$(current_port)"
    echo ""
    echo "Done."
}

case "${1:-}" in
    install)   do_install "${2:-}" ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
    *)         usage ;;
esac
