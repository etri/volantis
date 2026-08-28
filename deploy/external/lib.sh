#!/usr/bin/env bash
#
# Shared helpers for the UPF, the gNB and the UEs. Sourced by ../deploy-external.sh,
# by ../deploy-local.sh and by every script in this directory; it does nothing
# on its own.
#
# Nothing here knows which deployment it is running against. Every address is an
# argument: the cluster (or the single-machine control plane) publishes its own,
# this host has its own, and the two are told to each other rather than assumed.
# That is what lets one copy of these scripts serve a Kubernetes deployment and
# the single-machine one — ../deploy-local.sh is the same dispatcher with the
# loopback address plan filled in.
#
# --- the three addresses ---------------------------------------------------
#
# Everything outside a cluster needs to know exactly three things about the
# deployment it is joining, and knows nothing else about it:
#
#   --pran     where the gNB opens its SCTP association: pran-svc's
#              EXTERNAL-IP, in whichever cluster serves this cloud.
#   --gateway  where the UPF registers. gateway-svc's EXTERNAL-IP. This is also
#              the address whose route decides what the UPF advertises, so the
#              two cannot disagree.
#   --db       where subscribers are written. The MongoDB is ClusterIP by
#              design, so this is normally a `kubectl port-forward` on loopback;
#              on one machine it is the local mongo.
#
# Resolution order for every setting is flag > environment > saved > default,
# and the resolved set is saved on each run. That last part matters: the UPF and
# the UEs run under sudo, which strips the environment the first shot was given.

EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$EXT_DIR/../.." && pwd)"

BIN="${VOLANTIS_BIN:-$ROOT/bin}"
CFG="${VOLANTIS_EXT_CONFIG:-$EXT_DIR/config}"
RUN="${VOLANTIS_RUN:-$ROOT/deploy/run/external}"
LOGDIR="$RUN/log"
PIDDIR="$RUN/pid"
UEDIR="$RUN/ue"          # uegen's output: the provisioned profiles
GENDIR="$RUN/generated"  # rendered from those, and from config/
SETTINGS="$RUN/settings"

# Fixed by the protocol or by the manifests, not by this host.
NGAP_PORT_DEFAULT=38412  # TS 38.412
GW_PORT_DEFAULT=7777     # gateway.yaml
GTPU_PORT=2152           # TS 29.281; not configurable, in either direction
AGENT_PORT=7001
SBI_PORT=9001

# The private subnet each UE namespace is reached on. ueN gets 10.99.<N-1>.0/24,
# so every UE is its own subnet and the host side of ue1's veth is the address
# the gNB's radio link binds.
UE_NET_PREFIX="10.99"
GNB_NETNS_ADDR="${UE_NET_PREFIX}.0.1"

# --- settings --------------------------------------------------------------
PRAN="${VOLANTIS_PRAN:-}"
GATEWAY="${VOLANTIS_GATEWAY:-}"
DB="${VOLANTIS_DB:-}"
UPF_IP="${VOLANTIS_UPF_IP:-}"
UPF_BIND="${VOLANTIS_UPF_BIND:-}"
GNB_IP="${VOLANTIS_GNB_IP:-}"
N6_DEV="${VOLANTIS_N6_DEV:-}"
TRAN="${VOLANTIS_TRAN:-}"
CLOUD="${VOLANTIS_CLOUD:-}"
TAC="${VOLANTIS_TAC:-}"
NUM_UES="${VOLANTIS_NUM_UES:-}"
PROBE_TARGET="${VOLANTIS_PROBE_TARGET:-}"
POD_CIDR="${VOLANTIS_POD_CIDR:-}"
NODE_IP="${VOLANTIS_NODE_IP:-}"
LOG_LEVEL="${VOLANTIS_LOG_LEVEL:-}"
UE_SEED="${VOLANTIS_UE_SEED:-1}"

# Saved settings fill only what is still empty, so the environment wins over
# them and the flags parsed after this win over both.
[ -r "$SETTINGS" ] && . "$SETTINGS"

# What to tell the reader to type. These scripts are reached through two
# dispatchers and a hint naming the wrong one sends them to a command that does
# not take their arguments, so the name is a variable rather than a literal.
RUNNER="${VOLANTIS_RUNNER:-./deploy/deploy-external.sh}"

usage_options() {
  cat <<'OPT'
Options — the three addresses this host is told about the deployment:
  --pran ADDR[:PORT]    where the gNB opens NGAP/SCTP; pran-svc's EXTERNAL-IP
                        in that cloud's cluster (port defaults to 38412)
  --gateway ADDR[:PORT] where the UPF registers; gateway-svc's EXTERNAL-IP
                        (port defaults to 7777)
  --db URL|HOST[:PORT]  the subscription database; normally a port-forward,
                        so mongodb://127.0.0.1:27017

and about this host:
  --upf-ip ADDR         the UPF's N3/N4 address    (default: the source address
                        the route to --gateway picks, which is also what the
                        UPF's agent advertises)
  --upf-bind ADDR       the address the UPF's SBI and agent servers listen on
                        (default: every interface). Needed only where something
                        else on this host already holds 9001/7001 — which is
                        every single-machine deployment, and no cluster one
  --gnb-ip ADDR         the gNB's N2/N3 address    (default: likewise, toward
                        --pran)
  --n6-dev DEV          the interface UE traffic leaves by (default: the
                        default route's)
  --pod-cidr CIDR       the cluster's pod network, when this host has no route
                        to it — minikube with `minikube tunnel` is the usual case
  --node-ip ADDR        the node address to route --pod-cidr via

and about what to deploy:
  --tran NAME           transport network the UPF attaches to (default: tran1)
  --cloud NAME          value of the `cloud` mesh label (default: none; set it
                        in multi-cloud, where definitions select on it)
  --tac N               the TAC the gNB declares in NG Setup (default: 1)
  --ues N               how many subscribers to provision (default: 2)
  --probe ADDR          an address this host can reach, for the data-path test
  --log-level LEVEL     trace|debug|info|warn|error (default: info)
OPT
}

# parse_opts "$@" — consumes the options above, leaves the rest in ARGS.
ARGS=()
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --pran)      PRAN="${2:-}"; shift 2 ;;
      --gateway)   GATEWAY="${2:-}"; shift 2 ;;
      --db)        DB="${2:-}"; shift 2 ;;
      --upf-ip)    UPF_IP="${2:-}"; shift 2 ;;
      --upf-bind)  UPF_BIND="${2:-}"; shift 2 ;;
      --gnb-ip)    GNB_IP="${2:-}"; shift 2 ;;
      --n6-dev)    N6_DEV="${2:-}"; shift 2 ;;
      --pod-cidr)  POD_CIDR="${2:-}"; shift 2 ;;
      --node-ip)   NODE_IP="${2:-}"; shift 2 ;;
      --tran)      TRAN="${2:-}"; shift 2 ;;
      --cloud)     CLOUD="${2:-}"; shift 2 ;;
      --tac)       TAC="${2:-}"; shift 2 ;;
      --ues)       NUM_UES="${2:-}"; shift 2 ;;
      --probe)     PROBE_TARGET="${2:-}"; shift 2 ;;
      --log-level) LOG_LEVEL="${2:-}"; shift 2 ;;
      --)          shift; ARGS+=("$@"); break ;;
      *)           ARGS+=("$1"); shift ;;
    esac
  done
  resolve
}

# --- output ----------------------------------------------------------------
RED=""; GREEN=""; YELLOW=""; DIM=""; BOLD=""; OFF=""
if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
fi
step() { echo; echo "${BOLD}$*${OFF}"; }
ok()   { printf '  %s%-6s%s %s\n' "$GREEN" "ok" "$OFF" "$*"; }
warn() { printf '  %s%-6s%s %s\n' "$YELLOW" "warn" "$OFF" "$*"; }
bad()  { printf '  %s%-6s%s %s\n' "$RED" "FAIL" "$OFF" "$*"; }
note() { printf '         %s%s%s\n' "$DIM" "$*" "$OFF"; }
die()  { echo "${RED}error:${OFF} $*" >&2; exit 1; }

# --- host facts ------------------------------------------------------------
# The source address this host would use to reach somewhere. It is the same
# question the UPF's mesh agent asks about the registrar to decide what to
# advertise, so defaulting the UPF's own address from it makes the two agree by
# construction rather than by the operator copying a value twice.
src_toward() {
  [ -n "${1:-}" ] || return 1
  ip -4 route get "$1" 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

default_dev() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

host_port() { case "$1" in *:*) echo "${1%%:*} ${1##*:}" ;; *) echo "$1 $2" ;; esac; }

# db_host_port <url-or-hostport> — what to knock on to see whether it answers.
db_host_port() {
  local s="${1#mongodb://}"; s="${s#mongodb+srv://}"
  s="${s%%/*}"; s="${s##*@}"; s="${s%%,*}"   # one seed, no credentials
  host_port "$s" 27017
}

db_url() { case "$1" in mongodb://*|mongodb+srv://*) echo "$1" ;; *:*) echo "mongodb://$1" ;; *) echo "mongodb://$1:27017" ;; esac; }

iptables_bin() {
  local p
  for p in "$(command -v iptables 2>/dev/null)" /sbin/iptables /usr/sbin/iptables; do
    [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# UERANSIM's binaries: $UERANSIM, then PATH, then bin/ — where bin/README.md
# says to copy them — then the usual build directories.
ueransim_dir() {
  local d
  if [ -n "${UERANSIM:-}" ]; then echo "$UERANSIM"; return 0; fi
  d="$(command -v nr-gnb 2>/dev/null)" && { dirname "$d"; return 0; }
  for d in "$BIN" "$HOME/UERANSIM/build" /usr/local/UERANSIM/build /opt/UERANSIM/build; do
    [ -x "$d/nr-gnb" ] && { echo "$d"; return 0; }
  done
  return 1
}

host_resolver() {
  local r
  r="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)"
  # a systemd-resolved stub is local to the host namespace and answers nothing
  # from inside a UE's, so it is not a usable default
  case "$r" in 127.*|"") echo "${VOLANTIS_UE_DNS:-8.8.8.8}" ;; *) echo "$r" ;; esac
}

need_root() { [ "$(id -u)" = "0" ] || die "$* needs root — re-run with sudo"; }

port_free() {
  local proto="$1" addr="$2" port="$3" flag
  case "$proto" in udp) flag=-lnup ;; sctp) flag=-lnaS ;; *) flag=-lntp ;; esac
  ! ss $flag 2>/dev/null | awk -v a="$addr:$port" '$0 ~ a {found=1} END {exit !found}'
}

# The working directory belongs to whoever is running this deployment, not to
# root. Three of the shots need root — the UPF, the UEs, e2e — and if the tree
# they create stays root-owned then every later non-root shot cannot write its
# settings, and `cli` cannot even read the profiles uegen wrote. Hand it back to
# the invoking user, which is who sudo says asked.
mkdirs() {
  mkdir -p "$LOGDIR" "$PIDDIR" "$UEDIR" "$GENDIR" || return 1
  [ -n "${SUDO_UID:-}" ] && [ "$(id -u)" = "0" ] \
    && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$RUN" 2>/dev/null
  return 0
}

# --- resolution ------------------------------------------------------------
resolve() {
  TRAN="${TRAN:-tran1}"
  TAC="${TAC:-1}"
  NUM_UES="${NUM_UES:-2}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  DB="${DB:-mongodb://127.0.0.1:27017}"

  # An address may legitimately be unset — `check` is meant to be runnable
  # before anything is, and to say which one is missing.
  PRAN_ADDR=""; PRAN_PORT="$NGAP_PORT_DEFAULT"
  GW_ADDR="";   GW_PORT="$GW_PORT_DEFAULT"
  [ -n "$PRAN" ]    && { set -- $(host_port "$PRAN" "$NGAP_PORT_DEFAULT");  PRAN_ADDR="$1"; PRAN_PORT="$2"; }
  [ -n "$GATEWAY" ] && { set -- $(host_port "$GATEWAY" "$GW_PORT_DEFAULT"); GW_ADDR="$1";   GW_PORT="$2"; }
  set -- $(db_host_port "$DB");                        DB_ADDR="$1";   DB_PORT="$2"
  DB_URL="$(db_url "$DB")"

  # The UPF's address is derived from the route to the gateway, because that is
  # the same question its own mesh agent asks to decide what to advertise: the
  # two agree by construction instead of by the operator copying a value twice.
  #
  # The gNB's is derived the same way, from the route to Proxy-RAN — except when
  # that lands on the same address, since nr-gnb and the UPF both bind GTP-U's
  # 2152 and the port is fixed in both directions. Two cluster addresses reached
  # over one interface is the ordinary case (minikube publishes both its
  # LoadBalancers on the node bridge), and the host's primary address is then
  # the other end of the same host — so use it, and leave the collision to be
  # reported only when there is genuinely nothing else.
  [ -n "$UPF_IP" ] || UPF_IP="$(src_toward "$GW_ADDR")"
  if [ -z "$GNB_IP" ]; then
    GNB_IP="$(src_toward "$PRAN_ADDR")"
    if [ -n "$GNB_IP" ] && [ "$GNB_IP" = "$UPF_IP" ]; then
      local primary; primary="$(src_toward 1.1.1.1)"
      [ -n "$primary" ] && [ "$primary" != "$UPF_IP" ] && GNB_IP="$primary"
    fi
  fi
  [ -n "$N6_DEV" ] || N6_DEV="$(default_dev)"
  # UPF_BIND is deliberately not defaulted to UPF_IP. Binding one address
  # refuses the SBI on every other, and against a cluster the UPF is reached on
  # whichever of this host's addresses the mesh picked — so the wildcard is
  # right there and a specific address is right only when asked for.
}

save_settings() {
  mkdirs
  # A cache, not state: a shot that cannot write it still does its job, and
  # saying so twice per command would be worse than not saying it.
  [ -e "$SETTINGS" ] && [ ! -w "$SETTINGS" ] && return 0
  local d; d="$(ueransim_dir 2>/dev/null)"
  {
    echo "# written by $RUNNER — what the last run resolved."
    echo "# Every line fills a value only if it is still empty, so the environment"
    echo "# and the flags both still win. This exists because sudo strips the"
    echo "# environment the first shot was given."
    local v
    for v in PRAN GATEWAY DB UPF_IP UPF_BIND GNB_IP N6_DEV TRAN CLOUD TAC NUM_UES \
             PROBE_TARGET POD_CIDR NODE_IP LOG_LEVEL; do
      printf ': "${%s:=%s}"\n' "$v" "${!v}"
    done
    [ -n "$d" ] && printf ': "${UERANSIM:=%s}"\n' "$d"
  } > "$SETTINGS"
}

print_settings() {
  printf '  %-10s %s\n' "pran" "${PRAN_ADDR:-${RED}unset${OFF}}${PRAN_ADDR:+:$PRAN_PORT}"
  printf '  %-10s %s\n' "gateway" "${GW_ADDR:-${RED}unset${OFF}}${GW_ADDR:+:$GW_PORT}"
  printf '  %-10s %s\n' "database" "$DB_URL"
  printf '  %-10s %s\n' "upf" "${UPF_IP:-${RED}unresolved${OFF}}  ${DIM}n3 on $TRAN, n6 out ${N6_DEV:-?}, sbi on ${UPF_BIND:-every interface}${OFF}"
  printf '  %-10s %s\n' "gnb" "${GNB_IP:-${RED}unresolved${OFF}}  ${DIM}tac $TAC${OFF}"
  [ -n "$CLOUD" ] && printf '  %-10s %s\n' "cloud" "$CLOUD"
  return 0
}

# --- processes -------------------------------------------------------------
pidfile() { echo "$PIDDIR/$1.pid"; }
logfile() { echo "$LOGDIR/$1.log"; }

# alive <pid> [comm] — is that process running, and still ours?
#
# /proc is the test rather than `kill -0`, because the UPF and the UEs are
# started under sudo: signalling another user's process fails with EPERM, which
# would make a perfectly healthy root-owned component report as down to anyone
# who did not run `status` as root. Matching `comm` is what catches a pid file
# that outlived its process and had its pid recycled.
alive() {
  local pid="$1" comm="${2:-}"
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/comm" ]; then
    [ -z "$comm" ] || [ "$(cat "/proc/$pid/comm")" = "$comm" ] || return 1
    return 0
  fi
  # not Linux, or /proc is not mounted: this is all there is, and it under-reports
  # another user's processes
  kill -0 "$pid" 2>/dev/null
}

# running reports whether the component's recorded pid is alive and still ours.
running() {
  local pf; pf="$(pidfile "$1")"
  [ -f "$pf" ] || return 1
  alive "$(cat "$pf" 2>/dev/null)" "${2:-$1}"
}

stop_pid() {
  local name="$1" limit="${2:-50}" pf pid waited=0
  pf="$(pidfile "$name")"
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null)"
  # The pid file is only dropped once the process is known to be gone or has
  # been signalled. Removing it first would lose the handle on a process this
  # user cannot signal — a root-owned UPF, asked to stop without sudo.
  if ! alive "$pid"; then rm -f "$pf"; return 0; fi
  if ! kill -TERM "$pid" 2>/dev/null; then
    printf '  %-11s %scannot signal pid %s%s (started by another user — use sudo)\n' \
      "$name" "$YELLOW" "$pid" "$OFF"
    return 1
  fi
  rm -f "$pf"
  while alive "$pid" && [ "$waited" -lt "$limit" ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  if alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null
    printf '  %-11s %skilled%s (did not exit)\n' "$name" "$YELLOW" "$OFF"
  else
    printf '  %-11s stopped\n' "$name"
  fi
}

probe_url() {
  [ -n "${1:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -sf -m 2 -o /dev/null "$1"
}

wait_url() {
  local url="$1" secs="${2:-30}" deadline
  deadline=$((SECONDS + secs))
  command -v curl >/dev/null 2>&1 || { sleep "$secs"; return 0; }
  while [ $SECONDS -lt $deadline ]; do
    probe_url "$url" && return 0
    sleep 0.3
  done
  return 1
}

wait_log() {
  local f="$1" re="$2" secs="${3:-20}" deadline
  deadline=$((SECONDS + secs))
  while [ $SECONDS -lt $deadline ]; do
    [ -f "$f" ] && grep -qE "$re" "$f" && return 0
    sleep 0.3
  done
  return 1
}

# --- the route to the pod network ------------------------------------------
#
# The UPF is a mesh consumer as well as a producer: it pulls its data networks
# from NSM, and NSM is a pod. Where the cluster's pod network is not routable
# from this host — minikube is, with `minikube tunnel` reaching only the
# LoadBalancer addresses — the UPF registers, then blocks on a configuration
# pull that never answers, and anchors nothing. --pod-cidr/--node-ip say how to
# reach it; nothing here can guess them.
pod_route_ok() {
  [ -n "$POD_CIDR" ] || return 0
  ip -4 route show "$POD_CIDR" 2>/dev/null | grep -q .
}

pod_route_add() {
  [ -n "$POD_CIDR" ] && [ -n "$NODE_IP" ] || return 1
  pod_route_ok && return 0
  ip route add "$POD_CIDR" via "$NODE_IP" || return 1
  touch "$GENDIR/pod-route-added"
  return 0
}

pod_route_del() {
  [ -e "$GENDIR/pod-route-added" ] || return 0
  ip route del "$POD_CIDR" via "$NODE_IP" 2>/dev/null
  rm -f "$GENDIR/pod-route-added"
}

# --- UE network namespaces -------------------------------------------------
#
# Every UE gets its own. Without one the UE's address from the pool lands on
# uesimtun0 in the host's namespace, where it is a *local* address: the kernel
# drops decapsulated uplink as "martian source ... on dev upfgtp" before the
# FORWARD chain sees it, and the UE's own copy and the forwarded copy share one
# conntrack entry so the masquerade never applies. A separate namespace removes
# both rather than working around either.
#
#   ue1  10.99.0.2/24 <-> 10.99.0.1   the gNB's radio link lives on this one
#   ue2  10.99.1.2/24 <-> 10.99.1.1   plus a /32 back to the gNB
#
# The /32 is deliberate: once the PDU session is up the default route moves onto
# uesimtun0, and anything less specific would take the radio link with it and
# strand the UE from the gNB it is attached to.
netns_up() {
  local n="$1" ns sub host peer
  ns="ue$n"; sub=$((n - 1))
  host="${UE_NET_PREFIX}.$sub.1"; peer="${UE_NET_PREFIX}.$sub.2"

  if ip netns list 2>/dev/null | grep -qw "$ns"; then echo "$ns"; return 0; fi
  ip netns add "$ns" || return 1
  ip link add "v-$ns" type veth peer name "v-${ns}p" || return 1
  ip addr add "$host/24" dev "v-$ns"
  ip link set "v-$ns" up
  ip link set "v-${ns}p" netns "$ns"
  ip netns exec "$ns" ip addr add "$peer/24" dev "v-${ns}p"
  ip netns exec "$ns" ip link set "v-${ns}p" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route add default via "$host"
  [ "$n" -ne 1 ] && ip netns exec "$ns" ip route add "$GNB_NETNS_ADDR/32" via "$host"

  mkdir -p "/etc/netns/$ns"
  echo "nameserver $(host_resolver)" > "/etc/netns/$ns/resolv.conf"
  echo "$ns"
  return 0
}

netns_down() {
  local ns="ue$1"
  ip netns list 2>/dev/null | grep -qw "$ns" || return 0
  ip netns del "$ns" 2>/dev/null
  ip link del "v-$ns" 2>/dev/null
  rm -rf "/etc/netns/$ns"
  return 0
}

ue_tun() { ip netns exec "ue$1" ip -br addr 2>/dev/null | awk '/uesimtun/ {print $1}' | head -1; }

# The address the gNB's radio link binds. --gnb-ip until ue1's veth exists;
# after that, the address a UE in its own namespace can actually reach.
gnb_link_ip() {
  if ip -4 addr show 2>/dev/null | grep -qw "$GNB_NETNS_ADDR"; then
    echo "$GNB_NETNS_ADDR"
  else
    echo "$GNB_IP"
  fi
}
