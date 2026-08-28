#!/usr/bin/env bash
#
# The control plane: ten processes, in deployment order.
#
#   deploy/local/core.sh start|stop|status|logs <name>
#
# Reached through ../deploy-local.sh; see README.md for the address plan and
# what each component is. The UPF is not one of them: it runs outside a cluster
# in every deployment, and here as everywhere it is deploy/external/upf.sh that
# starts it — 'sudo ./deploy/deploy-local.sh upf', which checks the host, builds
# ue1's namespace and renders its configuration for this host first.
#
# Nothing here *requires* the order: a network function that comes up before NSM
# retries forever rather than exiting, and stays registered-but-unselectable
# until its configuration arrives. The order only keeps the logs quiet.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Each entry is  name:binary:config:readyURL  — readyURL may be empty.
COMPONENTS=(
  "controller:controller:controller.json:http://$CTRL_ADDR:$CTRL_PORT/ready"
  "gateway:gateway:gateway.json:http://$GW_ADDR:$GW_PORT/mon/endpoints"
  "nsm:nsm:nsm.json:http://$NSM_ADDR:$AGENT_PORT/ready"
  "udm:udm:udm.json:http://$UDM_ADDR:$AGENT_PORT/ready"
  "ausf:ausf:ausf.json:http://$AUSF_ADDR:$AGENT_PORT/ready"
  "pcf:pcf:pcf.json:http://$PCF_ADDR:$AGENT_PORT/ready"
  "damf:damf:damf.json:http://$DAMF_ADDR:$AGENT_PORT/ready"
  "amf:amf:amf.json:http://$AMF_ADDR:$AGENT_PORT/ready"
  "smf:smf:smf.json:http://$SMF_ADDR:$AGENT_PORT/ready"
  "pran:pran:pran.json:http://$PRAN_ADDR:$AGENT_PORT/ready"
)
# How long to wait for the controller and the gateway before starting the rest.
# Only these two are waited on: they are the ones whose absence produces a retry
# storm in every other log.
GATE_TIMEOUT=20

components() { printf '%s\n' "${COMPONENTS[@]}"; }

field()     { echo "$1" | cut -d: -f"$2"; }
# everything from field 4 on, because the URL contains colons
ready_url() { echo "$1" | cut -d: -f4-; }

start_one() {
  local name="$1" bin="$2" cfg="$3" pid
  if running "$name" "$bin"; then
    printf '  %-11s %salready running (pid %s)%s\n' "$name" "$DIM" "$(cat "$(pidfile "$name")")" "$OFF"
    return 0
  fi
  # stdout and stderr rather than the binary's own -l: a configuration error is
  # reported before the log file is opened, and this way it still lands in the
  # log instead of vanishing.
  nohup "$BIN/$bin" -c "$CFG/$cfg" -v "$LOG_LEVEL" >"$(logfile "$name")" 2>&1 &
  pid=$!
  echo "$pid" > "$(pidfile "$name")"

  # a process that dies on a bad config dies immediately; catch that here rather
  # than reporting it as started and leaving the operator to find the log
  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$(pidfile "$name")"
    printf '  %-11s %sfailed to start%s\n' "$name" "$RED" "$OFF"
    echo "${DIM}$(tail -n 5 "$(logfile "$name")" | sed 's/^/      /')${OFF}"
    return 1
  fi
  printf '  %-11s started (pid %s)\n' "$name" "$pid"
  return 0
}

cmd_start() {
  mkdirs
  echo "${DIM}bin=${BIN#$ROOT/} config=${CFG#$ROOT/} log level=$LOG_LEVEL${OFF}"

  local failed=0 entry name bin cfg url deadline
  while read -r entry; do
    [ -n "$entry" ] || continue
    name="$(field "$entry" 1)"; bin="$(field "$entry" 2)"
    cfg="$(field "$entry" 3)"; url="$(ready_url "$entry")"

    start_one "$name" "$bin" "$cfg" || { failed=1; break; }

    case "$name" in
      controller|gateway)
        if ! wait_url "$url" "$GATE_TIMEOUT"; then
          printf '  %-11s %sdid not become ready within %ss%s\n' \
            "$name" "$RED" "$GATE_TIMEOUT" "$OFF"
          echo "${DIM}$(tail -n 10 "$(logfile "$name")" | sed 's/^/      /')${OFF}"
          failed=1
          break
        fi
        ;;
    esac
  done < <(components)

  [ "$failed" = "1" ] && {
    echo "${RED}Start aborted.${OFF} './deploy/deploy-local.sh stop' cleans up what did come up."
    return 1
  }

  # Wait for the whole set rather than telling the operator to poll: a network
  # function is registered long before it is selectable, and "started" is not
  # the interesting moment.
  printf '  waiting for every component to pull its configuration from NSM'
  deadline=$((SECONDS + 60))
  while [ $SECONDS -lt $deadline ]; do
    local pending=0
    while read -r entry; do
      [ -n "$entry" ] || continue
      probe "$(ready_url "$entry")" || pending=1
    done < <(components)
    [ "$pending" = "0" ] && break
    printf '.'; sleep 1
  done
  echo
  return 0
}

cmd_stop() {
  local entry names=() name pf i seen
  while read -r entry; do
    [ -n "$entry" ] || continue
    names+=("$(field "$entry" 1)")
  done < <(components)

  # Anything with a pid file that is not a component here — in practice the UPF,
  # which this never starts. Stopping only what this invocation would start
  # leaves it holding its gtp5g link and its host rules, which is exactly what
  # the next run trips over. ../deploy-local.sh stops it properly before calling
  # this; the sweep is what catches a core.sh run on its own. Swept first, so
  # the ordered shutdown below still goes last.
  for pf in "$PIDDIR"/*.pid; do
    [ -e "$pf" ] || continue
    name="$(basename "$pf" .pid)"
    case "$name" in gnb|ue-*) continue ;; esac   # not ours; deploy-local.sh stops those
    seen=0
    for i in "${names[@]}"; do [ "$i" = "$name" ] && { seen=1; break; }; done
    [ "$seen" = "1" ] && continue
    names=("$name" "${names[@]}")
  done

  # reverse order: the controller is the last thing to go, so the components
  # still shutting down can still deregister
  for (( i=${#names[@]}-1 ; i>=0 ; i-- )); do
    stop_pid "${names[$i]}"
  done
  return 0
}

cmd_status() {
  local entry name url state ready color
  printf '%-12s %-8s %-7s %s\n' COMPONENT PROCESS READY ENDPOINT
  while read -r entry; do
    [ -n "$entry" ] || continue
    name="$(field "$entry" 1)"
    url="$(ready_url "$entry")"
    if running "$name" "$(field "$entry" 2)"; then
      state="up"; color="$GREEN"
      if probe "$url"; then
        ready="yes"
      else
        # not an error while the core is coming up: a network function answers
        # /ready with 503 until it has registered *and* pulled enough
        # configuration from NSM to be worth sending traffic to
        ready="no"; color="$YELLOW"
      fi
    else
      state="down"; ready="-"; color="$RED"
    fi
    # padded before colouring: escape sequences count toward printf's width
    printf '%-12s %s%-8s %-7s%s %s\n' "$name" "$color" "$state" "$ready" "$OFF" "${DIM}${url}${OFF}"
  done < <(components)
}

cmd_logs() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ./deploy/deploy-local.sh logs <component>"
  local lf; lf="$(logfile "$name")"
  [ -f "$lf" ] || die "no log at $lf"
  tail -f "$lf"
}

case "${1:-}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  logs)   shift; cmd_logs "$@" ;;
  *)      die "usage: core.sh start|stop|status|logs <name>" ;;
esac
