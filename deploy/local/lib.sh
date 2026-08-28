#!/usr/bin/env bash
#
# Shared helpers for the single-machine control plane. Sourced by
# ../deploy-local.sh and by core.sh and check.sh; it does nothing on its own.
#
# The address plan is here rather than in each script, because it is the one
# thing every part of this deployment has to agree on. It matches config/*.json
# and README.md; change one and you change all three. ../deploy-local.sh also
# hands it to deploy/external/ as command-line arguments, which is how the UPF,
# the gNB and the UEs — one shared copy, serving every deployment — learn where
# this one is.

# This directory, and the repository root two levels up.
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LOCAL_DIR/../.." && pwd)"

BIN="${VOLANTIS_BIN:-$ROOT/bin}"
CFG="${VOLANTIS_CONFIG:-$LOCAL_DIR/config}"
RUN="${VOLANTIS_RUN:-$ROOT/deploy/run}"
LOGDIR="$RUN/log"
PIDDIR="$RUN/pid"
UEDIR="$RUN/ue"          # uegen's output: the provisioned profiles
GENDIR="$RUN/generated"  # what the runners render from templates
# deploy/external/ writes its own resolved settings into $RUN, which is what
# carries UERANSIM's location and the probe target across sudo into the root
# shots. Nothing here has to write them down a second time.

LOG_LEVEL="${VOLANTIS_LOG_LEVEL:-info}"
NUM_UES="${VOLANTIS_NUM_UES:-2}"

# --- the address plan ------------------------------------------------------
# One loopback address per component; both default ports on each. A second
# replica of a function is a second address with the same ports, which is what
# a second pod is.
CTRL_ADDR=127.0.0.1;  CTRL_PORT=8888
GW_ADDR=127.0.0.2;    GW_PORT=7777
NSM_ADDR=127.0.0.3
PCF_ADDR=127.0.0.4
AUSF_ADDR=127.0.0.5
UDM_ADDR=127.0.0.6
DAMF_ADDR=127.0.0.7
PRAN_ADDR=127.0.0.8;  NGAP_PORT=38412
AMF_ADDR=127.0.0.9
SMF_ADDR=127.0.0.10
# The last two are this host's, not the core's: ../deploy-local.sh passes them
# as --upf-ip and --gnb-ip. They are two addresses rather than one because
# GTP-U's 2152 is fixed by TS 29.281 in both directions — it is the local bind
# port and the OUTER_HEADER_CREATION_PORT of every downlink tunnel — so the UPF
# and the simulated gNB can only share a host by holding it on different
# addresses.
UPF_ADDR=127.0.0.12
GNB_ADDR=127.0.0.13   # the simulated gNB's N2 and N3
SBI_PORT=9001
AGENT_PORT=7001
MONGO_ADDR=127.0.0.1; MONGO_PORT=27017

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

# --- processes -------------------------------------------------------------
pidfile() { echo "$PIDDIR/$1.pid"; }
logfile() { echo "$LOGDIR/$1.log"; }

# alive <pid> [comm] — is that process running, and still ours?
#
# /proc is the test rather than `kill -0`, because the UPF and the UEs are
# started under sudo: signalling another user's process fails with EPERM, which
# would make a perfectly healthy root-owned component report as down to anyone
# who did not run `status` as root. Matching `comm` is what catches a pid file
# that outlived its process — normal after a crash or a reboot — and had its pid
# recycled, which would otherwise make stop kill somebody else's process.
alive() {
  local pid="$1" comm="${2:-}"
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/comm" ]; then
    [ -z "$comm" ] || [ "$(cat "/proc/$pid/comm")" = "$comm" ] || return 1
    return 0
  fi
  # not Linux, or /proc is not mounted: this is all there is, and it
  # under-reports another user's processes
  kill -0 "$pid" 2>/dev/null
}

# running reports whether the component's recorded pid is alive and still ours.
running() {
  local pf; pf="$(pidfile "$1")"
  [ -f "$pf" ] || return 1
  alive "$(cat "$pf" 2>/dev/null)" "${2:-$1}"
}

# stop_pid <name> [signal-wait-tenths] — TERM, wait, then KILL.
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

probe() {
  local url="$1"
  [ -n "$url" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -sf -m 2 -o /dev/null "$url"
}

# wait_url <url> <seconds> — poll until it answers, or give up.
wait_url() {
  local url="$1" secs="${2:-30}" deadline
  deadline=$((SECONDS + secs))
  command -v curl >/dev/null 2>&1 || { sleep "$secs"; return 0; }
  while [ $SECONDS -lt $deadline ]; do
    probe "$url" && return 0
    sleep 0.3
  done
  return 1
}

# port_free <proto> <addr> <port> — udp/tcp/sctp, by listening socket.
port_free() {
  local proto="$1" addr="$2" port="$3" flag
  case "$proto" in udp) flag=-lnup ;; sctp) flag=-lnaS ;; *) flag=-lntp ;; esac
  ! ss $flag 2>/dev/null | awk -v a="$addr:$port" '$0 ~ a {found=1} END {exit !found}'
}

# The working directory belongs to whoever is running this deployment, not to
# root — see deploy/external/lib.sh, which does the same for the shots that need
# root and would otherwise leave a tree no later non-root shot can write.
mkdirs() {
  mkdir -p "$LOGDIR" "$PIDDIR" "$UEDIR" "$GENDIR" || return 1
  [ -n "${SUDO_UID:-}" ] && [ "$(id -u)" = "0" ] \
    && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$RUN" 2>/dev/null
  return 0
}

# What is deliberately not here any more: UERANSIM discovery, the UE network
# namespaces, the gNB's radio-link address, the N6 interface and iptables. Those
# belong to the UPF, the gNB and the UEs, which are deploy/external/'s — one
# copy, shared with the cluster deployments, so that the components this host
# runs outside a cluster and the ones it runs beside a cluster are the same.
