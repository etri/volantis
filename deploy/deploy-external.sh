#!/usr/bin/env bash
#
# Volantis — the components that run outside a cluster.
#
# The UPF, a UERANSIM gNB, the UEs and the subscriber provisioning. Every
# deployment in deploy/k8s/manifest/ uses these same scripts: what differs
# between them is the addresses, and those are arguments.
#
# The UPF is outside because its data path needs the gtp5g kernel module on the
# host. UERANSIM is outside because it is the radio, and the radio is not a
# cluster workload. Nothing else here is: in single-cloud even Proxy-RAN runs in
# the cluster, behind an SCTP LoadBalancer.
#
# Run it from the repository root, after the cluster deployment is up:
#
#   kubectl -n volantis get svc            # read the two EXTERNAL-IPs
#   kubectl -n volantis port-forward svc/udr-mongo 27017:27017 &
#
#   ./deploy/deploy-external.sh check --pran <IP> --gateway <IP>
#   ./deploy/deploy-external.sh subscribers
#   ./deploy/deploy-external.sh gnb
#   sudo ./deploy/deploy-external.sh upf
#   sudo ./deploy/deploy-external.sh ue 1
#
# `cli` opens UERANSIM's own nr-cli console on a running node, in whichever
# network namespace that node lives in:
#
#   ./deploy/deploy-external.sh cli             what is running
#   ./deploy/deploy-external.sh cli gnb         a console on the gNB
#   sudo ./deploy/deploy-external.sh cli ue 1   a console on UE 1
#
# Append a command to run that one and exit instead: `cli ue 1 ps-list`.
#
# or all of it at once, which is also the end-to-end test:
#
#   sudo ./deploy/deploy-external.sh e2e --pran <IP> --gateway <IP> --probe <IP>
#
# The addresses are remembered between shots, in deploy/run/external/settings — give
# them once. That file exists because sudo strips the environment the first shot
# was given, so the root shots would otherwise have to be told again.
#
# Everything this dispatches to lives in deploy/external/; see its README.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/deploy/external"
[ -d "$EXT" ] || { echo "error: no $EXT" >&2; exit 1; }

# Every component runs with the repository root as its working directory, not
# whichever directory the runner was invoked from. Configuration can name a
# relative path, and a relative path is resolved against the process's cwd, so
# a run started from inside deploy/ would quietly build a second tree beside
# the real one. Running from the root is what the README says to do; this makes
# it true rather than assumed. Relative values in
# VOLANTIS_BIN/VOLANTIS_EXT_CONFIG/VOLANTIS_RUN are therefore relative to the
# root as well, which is where they were read from.
cd "$ROOT" || { echo "error: cannot enter $ROOT" >&2; exit 1; }

. "$EXT/lib.sh"

cmd_status() {
  parse_opts "$@"
  step "Settings"
  print_settings
  step "Components"
  if running upf upf; then
    printf '%-12s %s%-8s%s %s\n' upf "$GREEN" up "$OFF" "${DIM}$UPF_IP  $(logfile upf)${OFF}"
  else
    printf '%-12s %s%-8s%s\n' upf "$RED" down "$OFF"
  fi
  "$EXT/gnb.sh" status
  "$EXT/ue.sh" status
}

cmd_stop() {
  parse_opts "$@"
  step "Stopping"
  # UEs and their namespaces first, then the gNB, then the UPF — each layer
  # deregisters from the one below it while that one is still there.
  if [ "$(id -u)" = "0" ]; then
    local f n
    for f in "$PIDDIR"/ue-*.pid; do
      [ -e "$f" ] || continue
      n="$(basename "$f" .pid)"; "$EXT/ue.sh" stop "${n#ue-}"
    done
    "$EXT/gnb.sh" stop
    "$EXT/upf.sh" stop
    netns_down 1
  else
    "$EXT/gnb.sh" stop
    if [ -e "$PIDDIR/upf.pid" ] || ls "$PIDDIR"/ue-*.pid >/dev/null 2>&1; then
      warn "the UPF and the UE namespaces need root: 'sudo ./deploy/deploy-external.sh stop'"
    fi
  fi
}

cmd_logs() {
  parse_opts "$@"; set -- "${ARGS[@]:-}"
  local f; f="$(logfile "${1:-upf}")"
  [ -f "$f" ] || die "no $f"
  tail -f "$f"
}

# The options are parsed here and saved; each script below re-reads them from
# deploy/run/external/settings, so only the positionals are handed on. That is also
# what lets the root shots be given no addresses at all.
case "${1:-}" in
  check)       shift; parse_opts "$@"; save_settings; exec "$EXT/check.sh" ${ARGS[@]+"${ARGS[@]}"} ;;
  subscribers) shift; parse_opts "$@"; save_settings; exec "$EXT/subscribers.sh" ${ARGS[@]+"${ARGS[@]}"} ;;
  gnb)         shift; parse_opts "$@"; save_settings; exec "$EXT/gnb.sh" ${ARGS[@]+"${ARGS[@]}"} ;;
  upf)         shift; parse_opts "$@"; save_settings; exec "$EXT/upf.sh" ${ARGS[@]+"${ARGS[@]}"} ;;
  ue)          shift; parse_opts "$@"; save_settings
               # `ue 1`, `ue 1 probe`, `ue probe 1` — the number is whichever
               # positional is a number, and the verb defaults to start.
               n=1; verb=start
               for a in ${ARGS[@]+"${ARGS[@]}"}; do
                 case "$a" in ''|*[!0-9]*) [ -n "$a" ] && verb="$a" ;; *) n="$a" ;; esac
               done
               exec "$EXT/ue.sh" "$verb" "$n" ;;
  # cli is told nothing about the deployment, so it has nothing to save.
  cli)         shift; parse_opts "$@"; exec "$EXT/cli.sh" ${ARGS[@]+"${ARGS[@]}"} ;;
  e2e)         shift; exec "$EXT/e2e.sh" "$@" ;;
  status)      shift; cmd_status "$@" ;;
  stop)        shift; cmd_stop "$@" ;;
  logs)        shift; cmd_logs "$@" ;;
  *)
    cat <<USAGE
Volantis — the components that run outside a cluster. Run from the repository root.

  ./deploy/deploy-external.sh check [addresses|db|gnb|upf|ue|all]
                                       requirements, without starting anything

  ./deploy/deploy-external.sh subscribers [provision [n]|list]
  ./deploy/deploy-external.sh gnb [start|stop|relink|status]
  sudo ./deploy/deploy-external.sh upf [start|stop|show]
  sudo ./deploy/deploy-external.sh ue 1 [start|probe|stop]

  sudo ./deploy/deploy-external.sh e2e   all of the above, as one test

  ./deploy/deploy-external.sh cli        list the running UERANSIM nodes
  ./deploy/deploy-external.sh cli gnb     an interactive console on the gNB
  sudo ./deploy/deploy-external.sh cli ue 1   an interactive console on UE 1
                                       (append a command to run just that one)

  ./deploy/deploy-external.sh status     what is running, and against what
  ./deploy/deploy-external.sh logs upf   tail one component's log
  sudo ./deploy/deploy-external.sh stop  shut it all down, namespaces too

$(usage_options)

Given once, the addresses are remembered in deploy/run/external/settings.
See deploy/external/README.md.
USAGE
    exit 1
    ;;
esac
