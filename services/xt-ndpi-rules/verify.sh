#!/usr/bin/env bash
set -uo pipefail

# End-to-end verification of the xt-ndpi-rules service, driven entirely through
# docker compose (the real deployment path). All iptables inspection happens
# INSIDE the service container (it has NET_ADMIN and shares the host netns), so
# this needs NO sudo — just a user who can talk to docker (the 'docker' group).
#
# Claims checked (PASS/FAIL):
#   1. Backend auto-detection: the service uses the iptables backend that owns
#      DOCKER-USER, applies the rule there, and detach removes it.
#   2. Loud failure: a non-existent chain crashes the container (it does not
#      silently no-op) — visible as a restart loop + error in the logs.
#   3. Blocking proof: a BitTorrent handshake is DELIVERED with no rule and
#      DROPPED once the service attaches (kernel DROP counter increments).
#   4. Source scoping: NDPI_SOURCE restricts the rule to one exit subnet.
#   5. Real exit-routed traffic: a container on the exit1 subnet sends a
#      BitTorrent handshake to the internet; the forwarded packet is caught by
#      the exit1 DOCKER-USER rule. With compose.exit2.yml loaded, also checks
#      that exit2 stays untouched when only exit1 is scoped (needs internet).
#
# Requirements (Ubuntu 24.04 TEST host — it adds/removes transient iptables
# rules): docker + compose, python3, xt_ndpi loaded
# (sudo ./setup-host/ndpi-setup.sh install), .debs built
# (./setup-host/ndpi-setup.sh build).
#
# Usage:
#   ./services/xt-ndpi-rules/verify.sh                 # all checks
#   ./services/xt-ndpi-rules/verify.sh 2>&1 | tee verify.log
# Exit status: 0 iff every check passes.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$HERE/../.." && pwd)"       # repo root (compose project dir)
SVC=xt-ndpi-rules
TEST_PORT=6881

PASS=0 FAIL=0
ok()  { echo "  [PASS] $*"; PASS=$((PASS+1)); }
no()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "=== $* ==="; }
# Match a pattern in a captured string via a here-string (no pipe -> no
# pipefail+SIGPIPE false negatives when grep -q exits early on a match).
has() { grep -qiE -- "$2" <<<"$1"; }

# Use docker without sudo if possible; fall back to sudo only if we must.
DC=docker
if ! docker info >/dev/null 2>&1; then
    DC="sudo docker"
    echo "note: cannot reach docker as $(id -un); falling back to 'sudo docker'." >&2
    echo "      add yourself to the 'docker' group to run this without sudo." >&2
fi

# Scratch dir: a dedicated subfolder under ~/tmp (never loose files in /tmp).
TMPBASE="${TMPDIR:-$HOME/tmp}"; mkdir -p "$TMPBASE"
WORK="$(mktemp -d "$TMPBASE/xt-ndpi-verify.XXXXXX")"

dc()       { ( cd "$COMPOSE_DIR" && $DC compose "$@" ); }
svc_rm()   { dc rm -sf "$SVC"   >/dev/null 2>&1 || true; }
svc_stop() { dc stop "$SVC"     >/dev/null 2>&1 || true; }
svc_logs() { dc logs "$SVC" 2>/dev/null; }
svc_exec() { dc exec -T "$SVC" "$@" 2>/dev/null; }     # run inside the service
rc_count() { $DC inspect -f '{{.RestartCount}}' "$SVC" 2>/dev/null || echo 0; }

svc_up() { # <chain> [source]   -> (re)create the service with this config
    svc_rm
    ( cd "$COMPOSE_DIR" && \
      NDPI_CHAIN="$1" NDPI_DROP=bittorrent NDPI_SOURCE="${2:-}" \
      $DC compose up -d "$SVC" ) >"$WORK/up.log" 2>&1
}

# Tear down via compose: removes the service + the exit1 network the probe
# created (the profile flag so the probe service is considered).
cleanup() {
    ( cd "$COMPOSE_DIR" && $DC compose --profile verify down --remove-orphans ) >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

# Deterministic BitTorrent peer-wire handshake over loopback, run as THIS user
# (no privilege needed). Prints DELIVERED or BLOCKED.
handshake_probe() {
    python3 - "$TEST_PORT" <<'PY'
import socket, threading, time, sys
PORT = int(sys.argv[1])
HS = b"\x13BitTorrent protocol" + b"\x00"*48
def server(out):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT)); s.listen(1); s.settimeout(8)
    try:
        c, _ = s.accept(); c.settimeout(5); out.append(c.recv(100))
    except Exception as e:
        out.append(e)
    finally:
        s.close()
out = []; t = threading.Thread(target=server, args=(out,)); t.start(); time.sleep(0.5)
c = socket.socket(); c.settimeout(5)
try:
    c.connect(("127.0.0.1", PORT)); c.sendall(HS)
except Exception:
    pass
t.join()
v = out[0] if out else None
print("DELIVERED" if isinstance(v, (bytes, bytearray)) and v else "BLOCKED")
PY
}

# Which iptables backend owns DOCKER-USER (asked inside the service container).
docker_user_ipt() {
    svc_exec sh -c 'iptables-legacy -n -L DOCKER-USER >/dev/null 2>&1 \
        && echo iptables-legacy || echo iptables-nft'
}

# Packet count for a source-scoped ndpi rule in DOCKER-USER (0 if absent).
du_pkts() { # <ipt-binary> <source-cidr>
    svc_exec "$1" -nvL DOCKER-USER 2>/dev/null \
        | awk -v s="$2" '$0 ~ s && /ndpi/ {print $1; exit}'
}

# Run the profiled ndpi-probe compose service on the real exit1 network: it
# opens a TCP connection to a sink on the internet and sends the BitTorrent
# handshake (so it forwards through DOCKER-USER). Prints "SRC <ip>" or "NOINET".
PROBE_PY='
import socket
try:
    s = socket.socket(); s.settimeout(6); s.connect(("1.1.1.1", 80))
    print("SRC", s.getsockname()[0])
    s.sendall(b"\x13BitTorrent protocol" + b"\x00"*48)
except Exception as e:
    print("NOINET", e)
'
run_probe() { ( cd "$COMPOSE_DIR" && $DC compose --profile verify run --rm "$1" "$PROBE_PY" ) 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "xt-ndpi-rules verification — $(date)"
echo "compose dir: $COMPOSE_DIR   docker: $DC"

hdr "Preconditions"
command -v python3 >/dev/null || { echo "missing: python3"; exit 2; }
$DC compose version >/dev/null 2>&1 || { echo "missing: docker compose"; exit 2; }
# The module need not be pre-loaded — the service modprobes it on start.
# Read /proc/modules directly: `lsmod | grep -q` would SIGPIPE lsmod under
# pipefail and falsely report "not loaded".
if grep -q '^xt_ndpi ' /proc/modules; then
    ok "xt_ndpi kernel module loaded"
elif modinfo xt_ndpi >/dev/null 2>&1; then
    ok "xt_ndpi installed (the service will load it on start)"
else
    no "xt_ndpi not installed (run: sudo ./setup-host/ndpi-setup.sh install)"; exit 2
fi
if ! ls "$COMPOSE_DIR"/ndpi/artifacts/xt-ndpi-iptables_*.deb >/dev/null 2>&1; then
    echo "  iptables .deb missing — run: ./setup-host/ndpi-setup.sh build"; exit 2
fi
echo "  building service image..."
dc build "$SVC" >"$WORK/build.log" 2>&1 && ok "service image built" \
    || { no "image build failed"; cat "$WORK/build.log"; exit 2; }

# --- 1. backend auto-detection on DOCKER-USER ------------------------------
hdr "1. Backend auto-detection (DOCKER-USER)"
svc_up DOCKER-USER; sleep 3
LOG="$(svc_logs)"
echo "$LOG" | grep -E 'backend|dropping' | sed 's/^/    log| /'
BE_LOG="$(echo "$LOG" | sed -n 's/.*chain DOCKER-USER -> \([a-z]*\) backend.*/\1/p' | head -1)"
BE_REAL="$(svc_exec sh -c 'iptables-legacy -n -L DOCKER-USER >/dev/null 2>&1 && echo legacy || (iptables-nft -n -L DOCKER-USER >/dev/null 2>&1 && echo nft || echo none)' | tr -d "[:space:]")"
echo "  log says: '${BE_LOG:-?}'   actual owner: '${BE_REAL:-?}'"
if [ -n "$BE_LOG" ] && [ "$BE_LOG" = "$BE_REAL" ]; then
    ok "service used the backend that owns DOCKER-USER ($BE_REAL)"
else
    no "backend mismatch (log='$BE_LOG' owner='$BE_REAL')"
fi
STAT="$(svc_exec bash /app/manage.sh status)"
has "$STAT" bittorrent && ok "rule present in DOCKER-USER" \
                       || no "rule not present in DOCKER-USER"
svc_exec bash /app/manage.sh detach >/dev/null
STAT="$(svc_exec bash /app/manage.sh status)"
has "$STAT" bittorrent && no "rule still present after detach" \
                       || ok "detach removes the rule"
svc_stop
LOG="$(svc_logs)"
has "$LOG" 'removed .* from DOCKER-USER' \
    && ok "detach runs automatically on container stop" \
    || no "no detach-on-stop in logs"
svc_rm

# --- 2. loud failure on a non-existent chain -------------------------------
hdr "2. Loud failure on a non-existent chain"
svc_up NOPE-CHAIN-XYZ; sleep 6
LOG="$(svc_logs)"
echo "$LOG" | grep -i error | sed 's/^/    log| /'
RC="$(rc_count)"
echo "  restart count: $RC"
{ [ "${RC:-0}" -gt 0 ] 2>/dev/null; } \
    && ok "container crash-loops (failed loudly, not a silent no-op)" \
    || no "container did not crash-loop"
has "$LOG" "ERROR: chain 'NOPE-CHAIN-XYZ' not found" \
    && ok "clear error message emitted" || no "no clear error message"
svc_rm

# --- 3. blocking proof on OUTPUT (control vs blocked) ----------------------
hdr "3. Blocking proof (BitTorrent handshake on OUTPUT)"
svc_rm
CTRL="$(handshake_probe)"
echo "  control (no service): $CTRL"
[ "$CTRL" = DELIVERED ] && ok "handshake delivered with no rule" \
                        || no "handshake not delivered in control (setup issue?)"
svc_up OUTPUT; sleep 3
svc_exec iptables -Z OUTPUT >/dev/null
BLK="$(handshake_probe)"
echo "  with service up:      $BLK"
[ "$BLK" = BLOCKED ] && ok "handshake blocked by the service rule" \
                     || no "handshake NOT blocked"
CNT="$(svc_exec iptables -nvL OUTPUT | awk '/ndpi.*bittorrent/{print $1; exit}')"
echo "  DROP counter (pkts):  ${CNT:-0}"
{ [ "${CNT:-0}" -gt 0 ] 2>/dev/null; } \
    && ok "DROP counter incremented (xt_ndpi matched)" \
    || no "DROP counter did not increment"
svc_rm

# --- 4. source scoping (restrict to one exit subnet) -----------------------
hdr "4. Source scoping (NDPI_SOURCE restricts to one exit)"
SCOPE="10.123.45.0/24"
svc_up OUTPUT "$SCOPE"; sleep 3
RULES="$(svc_exec iptables -nL OUTPUT)"
RULES="$(grep -i 'ndpi.*bittorrent' <<<"$RULES")"
echo "$RULES" | sed 's/^/    /'
has "$RULES" "$SCOPE" \
    && ok "rule scoped to source $SCOPE" \
    || no "rule NOT scoped to source $SCOPE"
has "$RULES" '0\.0\.0\.0/0[[:space:]]+0\.0\.0\.0/0' \
    && no "an unscoped (all-source) rule is also present" \
    || ok "no unscoped rule (traffic outside the scope is untouched)"
svc_rm

# --- 5. real exit-routed traffic through DOCKER-USER (per-exit) -------------
# ndpi-probe-exit1 / -exit2 run on the real exit networks and send a BitTorrent
# handshake out to the internet — FORWARDED by the host, so it traverses
# DOCKER-USER sourced from that exit's subnet, exactly like a VPN client.
# Proves each exit's rule catches its OWN traffic, and — when exit2 is loaded
# (compose.exit2.yml) — that one exit can be enforced while the other is left open.
hdr "5. Real exit-routed traffic via DOCKER-USER (per-exit)"

HAS_EXIT2=0
dc --profile verify config --services 2>/dev/null | grep -qx ndpi-probe-exit2 && HAS_EXIT2=1
[ "$HAS_EXIT2" = 1 ] && echo "  exits: exit1 + exit2" || echo "  exits: exit1 only (load compose.exit2.yml to test per-exit scoping)"

# warm up the probe image once; if unavailable -> skip the whole section
( cd "$COMPOSE_DIR" && $DC compose --profile verify pull -q ndpi-probe-exit1 ) >/dev/null 2>&1
PROBE_OK=1
INET="$(run_probe ndpi-probe-exit1)"
{ has "$INET" NOINET || [ -z "$INET" ]; } && PROBE_OK=0

if [ "$PROBE_OK" = 0 ]; then
    echo "  SKIP: probe image unavailable or no internet from the exit container"
elif [ "$HAS_EXIT2" = 0 ]; then
    echo "  [A] NDPI_SOURCE = exit1 -> exit1 caught by its own rule"
    svc_up DOCKER-USER "172.100.0.0/24"; sleep 3
    IPT="$(docker_user_ipt | tr -d '[:space:]')"
    svc_exec "$IPT" -Z DOCKER-USER >/dev/null
    S1="$(run_probe ndpi-probe-exit1)"; sleep 1
    svc_exec "$IPT" -nvL DOCKER-USER 2>/dev/null | grep ndpi | sed 's/^/    /'
    A1="$(du_pkts "$IPT" '172.100.0.0/24')"
    echo "    exit1 src $(awk '/SRC/{print $2;exit}' <<<"$S1") -> exit1 rule ${A1:-0} pkts"
    { [ "${A1:-0}" -gt 0 ] 2>/dev/null; } \
        && ok "exit1 caught on its own DOCKER-USER rule" \
        || no "exit1 was not caught (${A1:-0} pkts)"
else
    echo "  [A] NDPI_SOURCE = both exits -> each exit caught by its own rule"
    svc_up DOCKER-USER "172.100.0.0/24,172.101.0.0/24"; sleep 3
    IPT="$(docker_user_ipt | tr -d '[:space:]')"
    svc_exec "$IPT" -Z DOCKER-USER >/dev/null
    S1="$(run_probe ndpi-probe-exit1)"; S2="$(run_probe ndpi-probe-exit2)"; sleep 1
    svc_exec "$IPT" -nvL DOCKER-USER 2>/dev/null | grep ndpi | sed 's/^/    /'
    A1="$(du_pkts "$IPT" '172.100.0.0/24')"; A2="$(du_pkts "$IPT" '172.101.0.0/24')"
    echo "    exit1 src $(awk '/SRC/{print $2;exit}' <<<"$S1") -> exit1 rule ${A1:-0} pkts"
    echo "    exit2 src $(awk '/SRC/{print $2;exit}' <<<"$S2") -> exit2 rule ${A2:-0} pkts"
    { [ "${A1:-0}" -gt 0 ] && [ "${A2:-0}" -gt 0 ]; } 2>/dev/null \
        && ok "both exits caught on their own DOCKER-USER rule" \
        || no "an exit was not caught (exit1=${A1:-0} exit2=${A2:-0})"

    echo "  [B] NDPI_SOURCE = exit1 only -> exit1 blocked, exit2 left open"
    svc_up DOCKER-USER "172.100.0.0/24"; sleep 3
    svc_exec "$IPT" -Z DOCKER-USER >/dev/null
    run_probe ndpi-probe-exit1 >/dev/null; run_probe ndpi-probe-exit2 >/dev/null; sleep 1
    svc_exec "$IPT" -nvL DOCKER-USER 2>/dev/null | grep ndpi | sed 's/^/    /'
    B1="$(du_pkts "$IPT" '172.100.0.0/24')"; B2="$(du_pkts "$IPT" '172.101.0.0/24')"
    echo "    exit1 rule ${B1:-0} pkts    exit2 rule: ${B2:-<none>}"
    { [ "${B1:-0}" -gt 0 ] 2>/dev/null; } \
        && ok "exit1 still blocked" || no "exit1 not blocked"
    [ -z "$B2" ] \
        && ok "exit2 has no rule — left open (per-exit choice works)" \
        || no "exit2 unexpectedly has a rule / was caught (${B2})"
fi

# --- summary ---------------------------------------------------------------
hdr "Summary"
echo "  PASS: $PASS    FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && { echo "  RESULT: OK"; exit 0; } || { echo "  RESULT: FAILED"; exit 1; }