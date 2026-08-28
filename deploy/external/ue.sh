#!/usr/bin/env bash
#
# One UE, in its own network namespace. Root, because the namespace is.
#
#   sudo ./deploy/deploy-external.sh ue 1
#   sudo ./deploy/deploy-external.sh ue 1 probe
#   sudo ./deploy/deploy-external.sh ue 1 stop
#
# The profile uegen wrote is the provisioned truth and is not edited. What the
# simulator runs is rendered from it with one field changed — gnbSearchList,
# which is where this gNB's radio link happens to be, not something about the
# subscriber.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_opts "$@"; save_settings; set -- ${ARGS[@]+"${ARGS[@]}"}

profile_src()    { echo "$UEDIR/ue-$1.yaml"; }
profile_active() { echo "$GENDIR/ue-$1.yaml"; }

# render <n> <gnb-address> — the provisioned profile, pointed at this gNB.
render() {
  local n="$1" ip="$2"
  mkdirs
  # The item's own indentation is kept: uegen re-serialises the template, so
  # what it writes need not be indented the way the template was.
  awk -v ip="$ip" '
    /^gnbSearchList:/ { print; insearch = 1; next }
    insearch && /^[[:space:]]*-[[:space:]]/ {
      match($0, /^[[:space:]]*-[[:space:]]*/)
      print substr($0, 1, RLENGTH) ip; insearch = 0; next
    }
    { insearch = 0; print }
  ' "$(profile_src "$n")" > "$(profile_active "$n")"
}

cmd_start() {
  local n="$1" d ns tun addr
  need_root "a UE namespace"
  [ -f "$(profile_src "$n")" ] \
    || die "no $(profile_src "$n") — '$RUNNER subscribers' provisions them"
  d="$(ueransim_dir)" || die "nr-ue not found — see '$RUNNER check ue'"

  probe_url "http://$UPF_IP:$AGENT_PORT/ready" \
    || warn "no UPF is ready — this UE will register, and its PDU session will be refused"

  ns="$(netns_up "$n")" || die "could not create the ue$n namespace"
  render "$n" "$(gnb_link_ip)"

  if running "ue-$n" nr-ue; then
    printf '  %-11s %salready running (pid %s)%s\n' "ue-$n" "$DIM" "$(cat "$(pidfile "ue-$n")")" "$OFF"
  else
    nohup ip netns exec "$ns" "$d/nr-ue" -c "$(profile_active "$n")" \
      >"$(logfile "ue-$n")" 2>&1 &
    echo $! > "$(pidfile "ue-$n")"
    printf '  %-11s started in namespace %s, looking for a gNB at %s\n' \
      "ue-$n" "$ns" "$(gnb_link_ip)"
  fi

  if wait_log "$(logfile "ue-$n")" "Registration is successful" 25; then
    ok "registered  $(awk '/^supi:/ {print $2}' "$(profile_src "$n")")"
  else
    bad "not registered within 25s"
    tail -n 6 "$(logfile "ue-$n")" | sed 's/^/      /'
    return 1
  fi

  # On a first attach the UE answers the first Authentication Request with a
  # synchronisation failure and the core retries with a corrected SQN. That is
  # normal for a freshly provisioned subscriber, not a fault.
  grep -q "synchronisation failure\|Synch failure" "$(logfile "ue-$n")" 2>/dev/null \
    && note "one AKA synchronisation failure, then a retry — normal on a first attach"

  local waited=0
  while [ -z "$(ue_tun "$n")" ] && [ "$waited" -lt 20 ]; do sleep 0.5; waited=$((waited + 1)); done
  tun="$(ue_tun "$n")"
  if [ -z "$tun" ]; then
    bad "no tunnel interface — the PDU session did not come up"
    grep -E "PDU Session|error" "$(logfile "ue-$n")" | tail -3 | sed 's/^/      /'
    return 1
  fi
  addr="$(ip netns exec "$ns" ip -br addr show "$tun" | awk '{print $3}')"
  ok "PDU session up on $tun  $addr"

  # Send the namespace's default through the tunnel, or an application test
  # never touches the tunnel it is meant to test: only an explicitly bound probe
  # (ping -I) would use it and everything else leaves by the veth, which nothing
  # masquerades.
  ip netns exec "$ns" ip route replace default dev "$tun"
  ok "default route in $ns is now $tun"

  [ -n "$PROBE_TARGET" ] && { echo; cmd_probe "$n"; }
  return 0
}

cmd_probe() {
  local n="$1" ns tun
  ns="ue$n"
  need_root "reaching into a UE namespace"
  tun="$(ue_tun "$n")"
  [ -n "$tun" ] || die "ue$n has no tunnel interface — no PDU session"

  step "Data path from ue$n"
  if [ -z "$PROBE_TARGET" ]; then
    warn "--probe is not set, so there is nothing to ping"
    note "pick an address this host itself can reach. A network that blocks ICMP to"
    note "  8.8.8.8 makes a working tunnel look exactly like a broken one."
  else
    printf '  icmp   '
    ip netns exec "$ns" ping -c 3 -W 2 -q "$PROBE_TARGET" 2>&1 | awk '/packet loss/ {print}'
  fi
  printf '  dns    '
  ip netns exec "$ns" timeout 8 getent hosts example.com 2>&1 | head -1
  echo
  printf '  http   '
  ip netns exec "$ns" timeout 15 curl -sI -o /dev/null \
      -w '%{http_code} in %{time_total}s\n' http://example.com 2>&1

  # The honest reading: RX and TX both climbing means the tunnel carried it.
  step "The tunnel's own counters"
  awk -v d="$(grep -o '"devName"[^,]*' "$GENDIR/upf.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')" '
    BEGIN { if (d == "") d = "upfgtp" }
    $0 ~ d { gsub(/:/, " "); printf "  %s: RX %s pkts, TX %s pkts, TX errors %s\n", $1, $3, $11, $12 }
  ' /proc/net/dev
  note "a few TX errors are IPv6 router solicitations the kernel emits on a device"
  note "  that cannot carry them — cosmetic"
}

cmd_stop() {
  local n="$1"
  need_root "stopping a UE"
  stop_pid "ue-$n" 20
  netns_down "$n"
  echo "  namespace ue$n removed"
}

cmd_status() {
  local n f detail
  for f in "$PIDDIR"/ue-*.pid; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .pid)"; n="${n#ue-}"
    if running "ue-$n" nr-ue; then
      # reading into the namespace needs root, so as a plain user this reports
      # that the UE is up and stops there rather than printing an empty field
      if [ "$(id -u)" = "0" ]; then
        detail="$(ip netns exec "ue$n" ip -br addr 2>/dev/null | awk '/uesimtun/ {print $1" "$3}')"
      else
        detail="(namespace needs root to read)"
      fi
      printf '%-12s %s%-8s%s %s\n' "ue-$n" "$GREEN" up "$OFF" "${DIM}${detail}${OFF}"
    else
      printf '%-12s %s%-8s%s\n' "ue-$n" "$RED" down "$OFF"
    fi
  done
}

action="${1:-}"; shift 2>/dev/null || true
case "$action" in
  start)  cmd_start "${1:-1}" ;;
  probe)  cmd_probe "${1:-1}" ;;
  stop)   cmd_stop  "${1:-1}" ;;
  status) cmd_status ;;
  *)      die "usage: ue.sh start|probe|stop <n> | status" ;;
esac
