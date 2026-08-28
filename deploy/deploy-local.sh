#!/usr/bin/env bash
#
# Volantis — the single-machine deployment.
#
# The whole core as ordinary processes on one host, each bound to its own
# loopback address. No Kubernetes, no container runtime, no orchestrator: the
# mesh is required to work without one, and this is what that looks like.
#
# Run it from the repository root. Three commands bring up an end-to-end
# deployment, in this order:
#
#   ./deploy/deploy-local.sh start      control plane, subscribers, gNB (no root)
#   sudo ./deploy/deploy-local.sh upf   the user plane                  (root)
#   sudo ./deploy/deploy-local.sh ue 1  a UE, in its own netns          (root)
#
# Each checks the host's requirements before it starts anything; `check` runs
# those checks on their own. Everything else:
#
#   ./deploy/deploy-local.sh status         what is running, and whether ready
#   ./deploy/deploy-local.sh logs <name>    tail one component's log
#   ./deploy/deploy-local.sh ue 1 probe     the data-path tests, from a UE
#   sudo ./deploy/deploy-local.sh stop      shut it all down, namespaces too
#   ./deploy/deploy-local.sh cli gnb        an nr-cli console on the gNB
#   sudo ./deploy/deploy-local.sh cli ue 1  an nr-cli console on that UE
#
# --- what runs where -------------------------------------------------------
#
# The control plane is this deployment's own: deploy/local/ holds its address
# plan, its configuration and core.sh, which starts the ten processes in
# dependency order.
#
# The UPF, the gNB and the UEs are not. They are the same components that run
# outside a Kubernetes cluster, they are the same scripts, and deploy/external/
# is the only copy of them. Nothing in there knows which deployment it is
# serving — every address is an argument — so the single machine is just one
# more set of addresses, and it is this file that fills them in. Two runners,
# one implementation: what the single machine exercises is what a cluster
# deployment runs.
#
# Environment:
#   VOLANTIS_BIN            where the binaries are        (default ./bin)
#   VOLANTIS_CONFIG         where the configs are         (default ./deploy/local/config)
#   VOLANTIS_RUN            where pids and logs go        (default ./deploy/run)
#   VOLANTIS_LOG_LEVEL      trace|debug|info|warn|error   (default info)
#   VOLANTIS_NUM_UES        how many subscribers to provision      (default 2)
#   UERANSIM                UERANSIM's build directory, if not on PATH
#   VOLANTIS_N6_DEV         the interface UE traffic leaves by (default: the
#                           default route's)
#   VOLANTIS_PROBE_TARGET   an address this host can reach, for the data-path test
#   VOLANTIS_WITH_GNB       0 to leave the gNB to something else
#
# See deploy/local/README.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$ROOT/deploy/local"
EXT="$ROOT/deploy/external"
[ -d "$LOCAL" ] || { echo "error: no $LOCAL" >&2; exit 1; }
[ -d "$EXT" ]   || { echo "error: no $EXT — the UPF, the gNB and the UEs live there" >&2; exit 1; }

# Every component runs with the repository root as its working directory, not
# whichever directory the runner was invoked from. Configuration can name a
# relative path — deploy/local/config/nsm.json's lease store is
# `deploy/run/nsm-leases.json` — and a relative path is resolved against the
# process's cwd, so a run started from inside deploy/ would quietly build a
# second `deploy/deploy/run/` and lose every lease the first one holds. Running
# from the root is what the READMEs say to do; this makes it true rather than
# assumed. Relative values in VOLANTIS_BIN/VOLANTIS_CONFIG/VOLANTIS_RUN are
# therefore relative to the root as well, which is where they were read from.
cd "$ROOT" || { echo "error: cannot enter $ROOT" >&2; exit 1; }

. "$LOCAL/lib.sh"

WITH_GNB="${VOLANTIS_WITH_GNB:-1}"

# The out-of-cluster scripts share this deployment's working directory rather
# than keeping their own, so that one `deploy/run/log` holds every component's
# log and `stop` finds every pid. They are also told which dispatcher the reader
# actually typed, so their hints name this one and not deploy-external.sh.
export VOLANTIS_RUN="$RUN"
export VOLANTIS_RUNNER="./deploy/deploy-local.sh"

# --- the address plan, as arguments ----------------------------------------
#
# Everything deploy/external/ needs to know about the deployment it is joining.
# Against a cluster these are LoadBalancer addresses read out of kubectl; here
# they are lib.sh's plan, and passing them explicitly is what keeps the two
# halves of this file agreeing with config/*.json.
#
# --upf-bind is the one option no cluster deployment uses. There the UPF has a
# host to itself and takes every interface; here nine other processes already
# hold 9001 and 7001 on their own loopback addresses, so it is told which is
# its. --upf-ip and --gnb-ip are separate for GTP-U: the port is fixed by
# TS 29.281 in both directions, so two addresses is the only way the UPF and the
# simulated gNB share a host.
ext_opts() {
  set -- --pran "$PRAN_ADDR:$NGAP_PORT" \
         --gateway "$GW_ADDR:$GW_PORT" \
         --db "mongodb://$MONGO_ADDR:$MONGO_PORT" \
         --upf-ip "$UPF_ADDR" --upf-bind "$UPF_ADDR" \
         --gnb-ip "$GNB_ADDR" \
         --tran tran1 --ues "$NUM_UES" --log-level "$LOG_LEVEL"
  [ -n "${VOLANTIS_N6_DEV:-}" ]       && set -- "$@" --n6-dev "$VOLANTIS_N6_DEV"
  [ -n "${VOLANTIS_PROBE_TARGET:-}" ] && set -- "$@" --probe "$VOLANTIS_PROBE_TARGET"
  printf '%s\n' "$@"
}

# ext <script> <args...> — run one of the out-of-cluster scripts against this
# deployment. The addresses go first so that anything the caller passes wins.
ext() {
  local s="$1"; shift
  local opts=(); mapfile -t opts < <(ext_opts)
  "$EXT/$s" "${opts[@]}" "$@"
}

cmd_start() {
  step "Requirements"
  "$LOCAL/check.sh" core || die "requirements not met — nothing was started"
  [ "$WITH_GNB" = "1" ] && { ext check.sh gnb || {
      warn "starting without a gNB"; WITH_GNB=0; }; }

  step "Control plane"
  "$LOCAL/core.sh" start || return 1

  step "Subscribers"
  ext subscribers.sh provision || return 1

  if [ "$WITH_GNB" = "1" ]; then
    step "gNB"
    ext gnb.sh start || return 1
  fi

  step "Status"
  cmd_status
  echo
  echo "Next: ${BOLD}sudo ./deploy/deploy-local.sh upf${OFF} for the user plane, then ${BOLD}sudo ./deploy/deploy-local.sh ue 1${OFF}."
  echo "${DIM}Logs in ${LOGDIR#$ROOT/}. Mesh view: curl -s http://$CTRL_ADDR:$CTRL_PORT/mon/services | jq${OFF}"
  return 0
}

cmd_stop() {
  step "Stopping Volantis"
  # UEs and their namespaces first, then the gNB, then the user plane, then the
  # control plane in reverse deployment order — every layer deregisters from the
  # one below it while that one is still there.
  if [ "$(id -u)" = "0" ]; then
    local f n
    for f in "$PIDDIR"/ue-*.pid; do
      [ -e "$f" ] || continue
      n="$(basename "$f" .pid)"; ext ue.sh stop "${n#ue-}"
    done
    ext gnb.sh stop
    ext upf.sh stop
  else
    ext gnb.sh stop
    if [ -e "$PIDDIR/upf.pid" ] || ls "$PIDDIR"/ue-*.pid >/dev/null 2>&1; then
      warn "the user plane and the UE namespaces need root: 'sudo ./deploy/deploy-local.sh stop'"
    fi
  fi
  "$LOCAL/core.sh" stop
  return 0
}

cmd_status() {
  "$LOCAL/core.sh" status
  if running upf upf; then
    printf '%-12s %s%-8s%s %s\n' upf "$GREEN" up "$OFF" "${DIM}$UPF_ADDR  $(logfile upf)${OFF}"
  elif [ -e "$(pidfile upf)" ]; then
    printf '%-12s %s%-8s%s %s\n' upf "$RED" down "$OFF" "${DIM}stale pid file${OFF}"
  fi
  ext gnb.sh status
  ext ue.sh status
}

# The user plane needs more than its own requirements: it pulls its data
# networks from NSM before it opens N4, so a control plane that is not serving
# yet shows up as a UPF that registers and never becomes ready.
cmd_upf() {
  "$LOCAL/check.sh" cpup || die "the control plane is not serving — nothing was started"
  ext upf.sh "$@"
}

cmd_check() {
  case "${1:-all}" in
    core)      exec "$LOCAL/check.sh" core ;;
    cpup)      exec "$LOCAL/check.sh" cpup ;;
    gnb|upf|ue) ext check.sh "$1" ;;
    all)       "$LOCAL/check.sh" core; local rc=$?
               ext check.sh gnb || rc=1
               step "User plane"
               note "run 'sudo ./deploy/deploy-local.sh check upf' for the root-only checks"
               note "  (gtp5g, iptables, GTP-U)"
               return $rc ;;
    *)         die "unknown phase '$1' — one of: core cpup gnb upf ue all" ;;
  esac
}

case "${1:-}" in
  check)   shift; cmd_check "$@" ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status)  cmd_status ;;
  logs)    shift; exec "$LOCAL/core.sh" logs "$@" ;;
  gnb)     shift; ext gnb.sh "${1:-start}" ;;
  upf)     shift; cmd_upf "${1:-start}" ;;
  ue)      shift; n="${1:-1}"; shift 2>/dev/null || true
           ext ue.sh "${1:-start}" "$n" ;;
  cli)     shift; ext cli.sh "$@" ;;
  subscribers) shift; ext subscribers.sh "$@" ;;
  *)
    cat <<USAGE
Volantis — the single-machine deployment.  Run from the repository root.

  ./deploy/deploy-local.sh check [core|cpup|gnb|upf|ue|all]
                                     requirements, without starting anything

  ./deploy/deploy-local.sh start     control plane, subscribers, gNB   (no root)
  sudo ./deploy/deploy-local.sh upf  the user plane                    (root)
  sudo ./deploy/deploy-local.sh ue 1 a UE in its own network namespace (root)

  ./deploy/deploy-local.sh status         what is running, and whether it is ready
  ./deploy/deploy-local.sh logs <name>    tail one component's log
  ./deploy/deploy-local.sh ue 1 probe     run the data-path tests from a UE
  sudo ./deploy/deploy-local.sh stop      shut it all down

  ./deploy/deploy-local.sh cli        list the running UERANSIM nodes
  ./deploy/deploy-local.sh cli gnb     an interactive console on the gNB
  sudo ./deploy/deploy-local.sh cli ue 1   an interactive console on UE 1
                                    (append a command to run just that one)

Components: controller gateway nsm udm ausf pcf damf amf smf pran, then upf.

The control plane is deploy/local/; the UPF, the gNB and the UEs are the shared
out-of-cluster scripts in deploy/external/, given this deployment's addresses.
See deploy/local/README.md.
USAGE
    exit 1
    ;;
esac
