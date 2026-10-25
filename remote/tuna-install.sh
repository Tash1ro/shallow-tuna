#!/usr/bin/env bash
set -euo pipefail

# Install the whole shallow-tuna stack on a fresh Ubuntu server from your
# machine, over SSH. The script always logs in as root; the connection itself
# follows your ~/.ssh/config (the target may be an alias).
#
# deliberately do NOT resolve symlinks: when the script is invoked via a
# symlink from another dir, the env file is looked up next to the SYMLINK —
# so each project dir can hold its own tuna-adm.env beside its links
# (one env file shared with tuna-adm.sh — same TUNA_* namespace)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TUNA_ADM_ENV:-${SCRIPT_DIR}/tuna-adm.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

TARGET="${TUNA_INSTALL_TARGET:-}"
NEW_USER="${TUNA_INSTALL_USER:-tuna}"
SSH_PORT="${TUNA_INSTALL_SSH_PORT:-}"
REPO="${TUNA_INSTALL_REPO:-https://github.com/pr0n1x/shallow-tuna.git}"
BRANCH="${TUNA_INSTALL_BRANCH:-main}"
REMOTE_DIR="${TUNA_ADM_REMOTE_DIR:-shallow-tuna}"
EXIT_IP="${TUNA_INSTALL_EXIT_IP:-}"
AWG_PORT="${TUNA_INSTALL_AWG_PORT:-51820}"
HOST_ALIAS="${TUNA_INSTALL_NAME:-}"
USER_KEYS=()
ROOT_KEYS=()
[[ -n "${TUNA_INSTALL_USER_KEY:-}" ]] && USER_KEYS+=("$TUNA_INSTALL_USER_KEY")
[[ -n "${TUNA_INSTALL_ROOT_KEY:-}" ]] && ROOT_KEYS+=("$TUNA_INSTALL_ROOT_KEY")
WITH_WG=0
WITH_SUDO=0
COMPOSE_UP=1
FORWARD_AGENT=0

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name [options] HOST

Install shallow-tuna on a fresh Ubuntu server over SSH:
  1. create a regular user and authorize your public key(s)
  2. clone the repo into ~$NEW_USER/$REMOTE_DIR and write .env
  3. run the setup-host scripts (docker, amneziawg, xt_ndpi), compose up
  4. apply the sshd drop-in (setup-host/ssh-setup.sh): port, key auth only

HOST is a hostname/IP, an alias from ~/.ssh/config, or ssh://host:port.
The login is always root (do not put a user in HOST). The connection follows
your ssh config as is; when it names no IdentityFile for HOST, only the
default ~/.ssh/id_* keys are offered and then the password is asked, so a
full ssh agent cannot exhaust the server's MaxAuthTries.

Options:
  -u, --user NAME        regular user to create            (default: $NEW_USER)
  -n, --name NAME        ssh config aliases NAME and NAME-root printed at the end
                         (default: HOST without ssh://, port and a -root suffix)
  -k, --key FILE         public key to authorize for that user; repeatable
                         (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
  -K, --root-key FILE    public key to add to root's authorized_keys; repeatable
  -p, --ssh-port PORT    move sshd to this port            (default: keep current)
  -r, --repo URL         git URL to clone                  (default: $REPO)
  -b, --branch NAME      branch to check out               (default: $BRANCH)
      --exit-ip IP       external IP of exit1 for EXIT_ROUTES
                                                           (default: server's primary IP)
      --awg-port PORT    AWG_PORT in .env                  (default: $AWG_PORT)
      --wg               also install plain WireGuard and load compose.wg.yml
      --sudo             add the user to the sudo group
      --no-up            do not 'docker compose up' at the end
  -A                     forward the ssh agent (clone a private repo over ssh)
  -h, --help

Env (set in $ENV_FILE or the shell): TUNA_INSTALL_TARGET, TUNA_INSTALL_USER,
TUNA_INSTALL_USER_KEY, TUNA_INSTALL_ROOT_KEY, TUNA_INSTALL_SSH_PORT,
TUNA_INSTALL_REPO, TUNA_INSTALL_BRANCH, TUNA_INSTALL_EXIT_IP,
TUNA_INSTALL_AWG_PORT, TUNA_INSTALL_NAME, TUNA_ADM_REMOTE_DIR.

Examples:
  $base_name -K ~/.ssh/admin.pub 203.0.113.10
  $base_name -u tuna -k ~/.ssh/tuna.pub -K ~/.ssh/admin.pub -p 2222 203.0.113.10
  $base_name -k ~/.ssh/tuna.pub ssh://203.0.113.10:2222
  $base_name --wg --exit-ip 203.0.113.10 -A -r git@github.com:pr0n1x/shallow-tuna.git tuna-srv-root
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)     NEW_USER="$2"; shift 2 ;;
        -n|--name)     HOST_ALIAS="$2"; shift 2 ;;
        -k|--key)      USER_KEYS+=("$2"); shift 2 ;;
        -K|--root-key) ROOT_KEYS+=("$2"); shift 2 ;;
        -p|--ssh-port) SSH_PORT="$2"; shift 2 ;;
        -r|--repo)     REPO="$2"; shift 2 ;;
        -b|--branch)   BRANCH="$2"; shift 2 ;;
        --exit-ip)     EXIT_IP="$2"; shift 2 ;;
        --awg-port)    AWG_PORT="$2"; shift 2 ;;
        --wg)          WITH_WG=1; shift ;;
        --sudo)        WITH_SUDO=1; shift ;;
        --no-up)       COMPOSE_UP=0; shift ;;
        -A)            FORWARD_AGENT=1; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown option: $1" >&2; exit 1 ;;
        *)             TARGET="$1"; shift ;;
    esac
done

die() { echo "Error: $*" >&2; exit 1; }

[[ -n "$TARGET" ]] || die "no host given (hostname, ssh alias or ssh://host:port); see --help"
[[ "$TARGET" != *@* ]] || die "give only the host, the login is always root: '$TARGET'"
if [[ "$TARGET" == ssh://* ]]; then
    TARGET="ssh://root@${TARGET#ssh://}"
    HOST_NAME_ARG="${TARGET#ssh://root@}"; HOST_NAME_ARG="${HOST_NAME_ARG%%:*}"
else
    HOST_NAME_ARG="$TARGET"
    TARGET="root@$TARGET"
fi
HOST_ALIAS="${HOST_ALIAS:-${HOST_NAME_ARG%-root}}"
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid user name '$NEW_USER'"
[[ -z "$SSH_PORT" || "$SSH_PORT" =~ ^[0-9]+$ ]] || die "invalid ssh port '$SSH_PORT'"

if [[ ${#USER_KEYS[@]} -eq 0 ]]; then
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        [[ -f "$f" ]] && { USER_KEYS+=("$f"); break; }
    done
    [[ ${#USER_KEYS[@]} -gt 0 ]] || die "no public key found in ~/.ssh; pass one with --key"
fi
for f in "${USER_KEYS[@]}" "${ROOT_KEYS[@]}"; do
    [[ -f "$f" ]] || die "key file not found: $f"
    grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-)' "$f" || die "not a public key: $f"
done
read_keys() { local f; for f in "$@"; do grep -E '^(ssh-|ecdsa-|sk-)' "$f"; done; }
USER_KEYS_TEXT="$(read_keys "${USER_KEYS[@]}")"
ROOT_KEYS_TEXT=""
[[ ${#ROOT_KEYS[@]} -gt 0 ]] && ROOT_KEYS_TEXT="$(read_keys "${ROOT_KEYS[@]}")"

# One multiplexed connection for all steps (one auth prompt, if any).
CTL_DIR="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tuna-install.XXXXXX")"
SSH_OPTS=(-T -o ControlMaster=auto -o ControlPath="$CTL_DIR/%C" -o ControlPersist=600
          -o ServerAliveInterval=30)
[[ "$FORWARD_AGENT" = 1 ]] && SSH_OPTS+=(-A)
SSH_CFG="$(ssh -T -G "$TARGET")"
HOSTNAME_ONLY="$(awk '/^hostname /{print $2; exit}' <<<"$SSH_CFG")"
CURRENT_PORT="$(awk '/^port /{print $2; exit}' <<<"$SSH_CFG")"
# No IdentityFile configured for this host: offer only the default key files,
# not every agent key (each one burns an attempt out of the server's MaxAuthTries).
if ! awk '/^identityfile /{print $2}' <<<"$SSH_CFG" \
     | grep -qvE '^~/\.ssh/id_(rsa|dsa|ecdsa|ecdsa_sk|ed25519|ed25519_sk|xmss)$'; then
    SSH_OPTS+=(-o IdentitiesOnly=yes)
fi
cleanup() { ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true; rm -rf "$CTL_DIR"; }
trap cleanup EXIT

remote() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# Run a bash script (stdin) as root on the server, with positional args.
# The script is passed as a bash -c argument, not piped: with 'bash -s' a
# child that reads stdin (docker compose run) would eat the rest of it.
# ssh -n keeps the remote stdin at /dev/null for the same reason.
remote_root() {
    local script args
    script="export LC_ALL=C.UTF-8"$'\n'"$(cat)"
    args="$(printf '%q ' "$@")"
    remote -n "bash -c $(printf '%q' "$script") bash $args"
}

step() { echo; echo "══ $* ══"; }

# ---------------------------------------------------------------------------
step "Preflight: $TARGET"
remote true || die "cannot connect to $TARGET"
OS_ID="$(remote '. /etc/os-release && echo "$ID $VERSION_ID"')"
echo "  server: $OS_ID, kernel $(remote uname -r)"
[[ "$OS_ID" == ubuntu* ]] || die "the setup-host scripts target Ubuntu, got '$OS_ID'"
# step 4 disables password auth: root must keep a key, or be given one with -K
if [[ ${#ROOT_KEYS[@]} -eq 0 ]] && ! remote 'grep -qsE "^(ssh-|ecdsa-|sk-)" /root/.ssh/authorized_keys'; then
    die "root has no authorized key and no -K was given; after step 4 disables password auth root would be locked out"
fi
if [[ -z "$EXIT_IP" ]]; then
    EXIT_IP="$(remote 'ip -4 route get 1.1.1.1 | sed -n "s/.* src \([0-9.]*\).*/\1/p"')"
    [[ -n "$EXIT_IP" ]] || die "could not detect the server's primary IP; pass --exit-ip"
fi
echo "  user: $NEW_USER   repo: $REPO ($BRANCH) -> ~$NEW_USER/$REMOTE_DIR"
echo "  exit1 -> $EXIT_IP   AWG_PORT=$AWG_PORT   sshd port: ${SSH_PORT:-keep ($CURRENT_PORT)}"
echo "  user keys: ${USER_KEYS[*]}"
[[ ${#ROOT_KEYS[@]} -gt 0 ]] && echo "  root keys: ${ROOT_KEYS[*]}"

# ---------------------------------------------------------------------------
step "1. User $NEW_USER"
remote_root "$NEW_USER" "$WITH_SUDO" "$USER_KEYS_TEXT" "$ROOT_KEYS_TEXT" <<'REMOTE'
set -euo pipefail
user="$1" with_sudo="$2" user_keys="$3" root_keys="$4"

if id -u "$user" >/dev/null 2>&1; then
    echo "  user exists"
else
    adduser --disabled-password --gecos '' "$user"
fi
[[ "$with_sudo" = 1 ]] && usermod -aG sudo "$user" && echo "  added to sudo"

add_keys() { # <home> <owner> <keys>
    local home="$1" owner="$2" keys="$3" line
    [[ -n "$keys" ]] || return 0
    install -d -m 700 -o "$owner" -g "$owner" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$home/.ssh/authorized_keys" || echo "$line" >> "$home/.ssh/authorized_keys"
    done <<<"$keys"
    chmod 600 "$home/.ssh/authorized_keys"
    chown "$owner:$owner" "$home/.ssh/authorized_keys"
    echo "  $home/.ssh/authorized_keys: $(wc -l < "$home/.ssh/authorized_keys") key(s)"
}
add_keys "$(getent passwd "$user" | cut -d: -f6)" "$user" "$user_keys"
add_keys /root root "$root_keys"
REMOTE

# ---------------------------------------------------------------------------
step "2. Clone $REPO"
remote_root "$NEW_USER" "$REPO" "$BRANCH" "$REMOTE_DIR" "$FORWARD_AGENT" "$EXIT_IP" "$AWG_PORT" "$WITH_WG" <<'REMOTE'
set -euo pipefail
user="$1" repo="$2" branch="$3" dir="$4" agent="$5" exit_ip="$6" awg_port="$7" with_wg="$8"
home="$(getent passwd "$user" | cut -d: -f6)"
dest="$home/$dir"

command -v git >/dev/null || { apt-get update -qq; apt-get install -y -qq git; }

if [[ -d "$dest/.git" ]]; then
    echo "  $dest exists — updating to origin/$branch"
    runuser -u "$user" -- git -C "$dest" fetch origin "$branch"
    runuser -u "$user" -- git -C "$dest" pull --ff-only \
        || runuser -u "$user" -- git -C "$dest" reset --hard "origin/$branch"
elif [[ "$agent" = 1 ]]; then
    # the forwarded agent socket is root-only, so clone as root and hand over
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git clone -b "$branch" "$repo" "$dest"
    chown -R "$user:$user" "$dest"
else
    runuser -u "$user" -- git clone -b "$branch" "$repo" "$dest"
fi

if [[ -f "$dest/.env" ]]; then
    echo "  .env exists — left as is"
else
    {
        echo "AWG_PORT=$awg_port"
        echo "EXIT_ROUTES=172.100.0.1:$exit_ip"
        if [[ "$with_wg" = 1 ]]; then echo "COMPOSE_FILE=compose.yml:compose.wg.yml"; fi
    } > "$dest/.env"
    chown "$user:$user" "$dest/.env"
    echo "  .env written:"; sed 's/^/    /' "$dest/.env"
fi
REMOTE

# ---------------------------------------------------------------------------
step "3. Host setup (setup-host/*)"
remote_root "$NEW_USER" "$REMOTE_DIR" "$WITH_WG" "$COMPOSE_UP" <<'REMOTE'
set -euo pipefail
user="$1" dir="$2" with_wg="$3" compose_up="$4"
home="$(getent passwd "$user" | cut -d: -f6)"
cd "$home/$dir"
export DEBIAN_FRONTEND=noninteractive

echo "── docker ──"
./setup-host/docker-setup.sh install
usermod -aG docker "$user"

echo; echo "── amneziawg ──"
./setup-host/amneziawg-setup.sh install

if [[ "$with_wg" = 1 ]]; then
    echo; echo "── wireguard ──"
    ./setup-host/wireguard-setup.sh install
fi

echo; echo "── xt_ndpi ──"
runuser -u "$user" -- ./setup-host/ndpi-setup.sh build
./setup-host/ndpi-setup.sh install

if [[ "$compose_up" = 1 ]]; then
    echo; echo "── docker compose up ──"
    runuser -u "$user" -- docker compose up -d --build
    runuser -u "$user" -- docker compose ps
fi
REMOTE

# ---------------------------------------------------------------------------
step "4. sshd (setup-host/ssh-setup.sh)"
remote_root "$NEW_USER" "$REMOTE_DIR" "$SSH_PORT" <<'REMOTE'
set -euo pipefail
user="$1" dir="$2" port="$3"
home="$(getent passwd "$user" | cut -d: -f6)"
"$home/$dir/setup-host/ssh-setup.sh" install ${port:+"$port"}
REMOTE

FINAL_PORT="${SSH_PORT:-$CURRENT_PORT}"
step "Verify: $NEW_USER@$HOSTNAME_ONLY:$FINAL_PORT"
# offer only the private keys matching the authorized public keys, if present
# (a key that is not in the agent would otherwise be tried after every agent key)
VERIFY_OPTS=()
for f in "${USER_KEYS[@]}"; do
    [[ "$f" == *.pub && -f "${f%.pub}" ]] && VERIFY_OPTS+=(-i "${f%.pub}")
done
[[ ${#VERIFY_OPTS[@]} -eq 0 ]] || VERIFY_OPTS+=(-o IdentitiesOnly=yes)
if ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "${VERIFY_OPTS[@]}" \
       -p "$FINAL_PORT" "$NEW_USER@$HOSTNAME_ONLY" "cd '$REMOTE_DIR' && docker compose ps --format '  {{.Name}}: {{.Status}}'"; then
    echo "  login as $NEW_USER on port $FINAL_PORT works"
else
    echo "  WARNING: could not log in as $NEW_USER@$HOSTNAME_ONLY -p $FINAL_PORT" >&2
    echo "           keep the current root session and check: ssh -p $FINAL_PORT root@$HOSTNAME_ONLY" >&2
    exit 1
fi

# private key next to the first given .pub, for the ssh config sample
identity_of() { local f; for f in "$@"; do [[ "$f" == *.pub ]] && { echo "${f%.pub}"; return; }; done; true; }
host_block() { # <alias> <login> <identity>
    echo "  Host $1"
    echo "      HostName $HOSTNAME_ONLY"
    echo "      Port $FINAL_PORT"
    echo "      User $2"
    [[ -z "$3" ]] || { echo "      IdentityFile $3"; echo "      IdentitiesOnly yes"; }
    echo
}
echo
echo "Done. Add to ~/.ssh/config:"
echo
host_block "$HOST_ALIAS" "$NEW_USER" "$(identity_of "${USER_KEYS[@]}")"
[[ ${#ROOT_KEYS[@]} -eq 0 ]] || host_block "$HOST_ALIAS-root" root "$(identity_of "${ROOT_KEYS[@]}")"
[[ "$HOST_ALIAS" =~ ^[0-9.:]+$ ]] && echo "  (pass -n NAME for a readable alias instead of the IP)" && echo
cat <<EOF
Then set TUNA_ADM_SSH_HOST=$HOST_ALIAS in tuna-adm.env, open the admin
panel with 'remote/tuna-adm.sh awg start' and finish the awg-easy setup
(host, port $AWG_PORT, admin account, obfuscation params) at http://127.0.0.1:51821.
EOF
