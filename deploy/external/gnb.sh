#!/usr/bin/env bash
#
# The simulated gNB.
#
#   ./deploy/deploy-external.sh gnb [start|stop|relink|status] --pran ADDR
#
# UERANSIM's nr-gnb, holding one SCTP association to Proxy-RAN. It knows no AMF
# address at all — that is what lets AMF instances come and go behind it.
#
# The radio link is the one address that moves. Until the UE namespaces exist
# the gNB binds --gnb-ip, which is enough for NG Setup; once ue1's veth is up it
# has to be an address a UE in its own namespace can reach, and `relink`
# restarts the gNB on it. N2 and N3 stay on --gnb-ip throughout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_opts "$@"; save_settings; set -- ${ARGS[@]+"${ARGS[@]}"}

TEMPLATE="$CFG/ueransim/gnb.yaml"
ACTIVE="$GENDIR/gnb.yaml"

# render <linkIp> — the shipped template with this run's addresses substituted,
# so the template itself stays the documented default and is never rewritten.
render() {
  mkdirs
  sed -e "s|GNB_HOST_IP|$GNB_IP|g" \
      -e "s|PRAN_ADDR|$PRAN_ADDR|" \
      -e "s|PRAN_PORT|$PRAN_PORT|" \
      -e "s|GNB_TAC|$TAC|" \
      "$TEMPLATE" \
    | sed "s|^linkIp:.*|linkIp: $1   # rendered by deploy/external/gnb.sh|" > "$ACTIVE"
}

# The address the running gNB actually bound, from the config it was started
# with — not from the template.
active_link_ip() { awk '/^linkIp:/ {print $2}' "$ACTIVE" 2>/dev/null; }

cmd_start() {
  local d link
  [ -n "$PRAN_ADDR" ] || die "--pran is required: the gNB has nowhere to open its association"
  [ -n "$GNB_IP" ]    || die "--gnb-ip could not be resolved from the route to $PRAN_ADDR; give it"
  d="$(ueransim_dir)" || die "nr-gnb not found — see '$RUNNER check gnb'"

  if running gnb nr-gnb; then
    printf '  %-11s %salready running (pid %s, radio link %s)%s\n' \
      gnb "$DIM" "$(cat "$(pidfile gnb)")" "$(active_link_ip)" "$OFF"
    return 0
  fi
  link="$(gnb_link_ip)"
  render "$link"
  nohup "$d/nr-gnb" -c "$ACTIVE" >"$(logfile gnb)" 2>&1 &
  echo $! > "$(pidfile gnb)"
  sleep 0.5
  running gnb nr-gnb || {
    rm -f "$(pidfile gnb)"
    bad "the gNB failed to start"
    echo "${DIM}$(tail -n 5 "$(logfile gnb)" | sed 's/^/      /')${OFF}"
    return 1
  }
  printf '  %-11s started (pid %s), radio link %s, N2 to %s:%s\n' \
    gnb "$(cat "$(pidfile gnb)")" "$link" "$PRAN_ADDR" "$PRAN_PORT"

  if wait_log "$(logfile gnb)" "NG Setup procedure is successful" 20; then
    ok "NG Setup succeeded — the gNB is attached to Proxy-RAN"
  else
    bad "no 'NG Setup procedure is successful' within 20s"
    note "$(tail -n 3 "$(logfile gnb)" 2>/dev/null | tr '\n' ' ')"
    note "check that $PRAN_ADDR:$PRAN_PORT is the address PRAN is published on, and"
    note "  that whatever publishes it is still running — a LoadBalancer address"
    note "  with no tunnel behind it accepts nothing and times out exactly like this"
    return 1
  fi

  # NG Setup is SCTP and says nothing about the other two sockets. A gNB whose
  # radio link or N3 failed to bind completes it anyway and reports itself
  # attached, and the failure surfaces much later as a UE that finds no cell —
  # so read the log for it here, where the address that is taken can be named.
  if grep -q 'Socket bind failed' "$(logfile gnb)" 2>/dev/null; then
    bad "the gNB is attached but could not bind all of its sockets"
    grep 'Socket bind failed' "$(logfile gnb)" | tail -2 | sed 's/^/      /'
    note "something already holds $link:4997 (the radio link) or $GNB_IP:$GTPU_PORT (N3),"
    note "  usually an nr-gnb left from an earlier run that this runner did not start."
    note "  Every UE will report 'no cells in coverage'. Find it with 'ss -lnup'."
    return 1
  fi
  return 0
}

cmd_stop() { stop_pid gnb; }

# relink restarts the gNB only when the address it should hold has changed —
# doing it on every user-plane start would otherwise tear down a working
# association for nothing.
cmd_relink() {
  local want; want="$(gnb_link_ip)"
  running gnb nr-gnb || { cmd_start; return $?; }
  if [ "$(active_link_ip)" = "$want" ]; then
    printf '  %-11s %sradio link already on %s%s\n' gnb "$DIM" "$want" "$OFF"
    return 0
  fi
  echo "  relinking the gNB radio link onto $want so UEs in their own namespace can reach it"
  cmd_stop
  cmd_start
}

cmd_status() {
  if running gnb nr-gnb; then
    printf '%-12s %s%-8s%s radio link %s  %s\n' gnb "$GREEN" up "$OFF" \
      "$(active_link_ip)" "${DIM}$(logfile gnb)${OFF}"
  else
    printf '%-12s %s%-8s%s\n' gnb "$RED" down "$OFF"
  fi
}

case "${1:-start}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  relink) cmd_relink ;;
  status) cmd_status ;;
  *)      die "usage: gnb.sh [start|stop|relink|status]" ;;
esac
