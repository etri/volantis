#!/usr/bin/env bash
#
# The user plane. Root, because it is the one component that touches the kernel.
#
#   sudo ./deploy/deploy-external.sh upf [start|stop|show] --gateway ADDR
#
# What it does, and why each part is here:
#
#   the checks      gtp5g, iptables, a free GTP-U port, a reachable gateway —
#                   every one of them is a failure that otherwise shows up as a
#                   UE whose PDU session is refused, several minutes later
#   the pod route   the UPF is a mesh *consumer* too: it pulls its data networks
#                   from NSM, which is a pod. Where this host has no route to the
#                   pod network, --pod-cidr/--node-ip is how it gets one
#   ue1's namespace so that the gNB's radio link has an address a UE outside the
#                   host namespace can reach
#   the render      the host-specific values in config/upf.json, substituted
#                   rather than left for every reader to edit in place
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_opts "$@"; save_settings; set -- ${ARGS[@]+"${ARGS[@]}"}

TEMPLATE="$CFG/upf.json"
ACTIVE="$GENDIR/upf.json"

render() {
  mkdirs
  sed -e "s|UPF_HOST_IP|$UPF_IP|g" \
      -e "s|TRANSPORT_NETWORK|$TRAN|" \
      -e "s|N6_DEVICE|$N6_DEV|" \
      -e "s|GATEWAY_ADDR|$GW_ADDR:$GW_PORT|" \
      "$TEMPLATE" > "$ACTIVE"
  # The SBI and agent servers take every interface unless told otherwise, which
  # is what a host running one UPF wants. A single-machine deployment is the
  # other case: nine other processes already hold 9001 and 7001 on their own
  # loopback addresses, so the UPF has to be told which one is its.
  if [ -n "$UPF_BIND" ]; then
    sed -i "s|UPF_BIND_ADDR|$UPF_BIND|" "$ACTIVE"
  else
    sed -i '/UPF_BIND_ADDR/d' "$ACTIVE"
  fi
  # The `cloud` label is a multi-cloud concern: there, definitions select on it
  # and an instance without it is in no definition. In a single cloud nothing
  # selects on it, and a label nothing matches is worse than absent — it is one
  # more key to get wrong. So the template carries it first and it is dropped
  # here when there is no cloud to name.
  [ -n "$CLOUD" ] || sed -i '/"cloud": "CLOUD_NAME",/d' "$ACTIVE"
  [ -n "$CLOUD" ] && sed -i "s|\"cloud\": \"CLOUD_NAME\"|\"cloud\": \"$CLOUD\"|" "$ACTIVE"
  return 0
}

cmd_start() {
  need_root "the UPF"
  [ -n "$GW_ADDR" ] || die "--gateway is required: the UPF has nowhere to register"
  [ -n "$UPF_IP" ]  || die "--upf-ip could not be resolved from the route to $GW_ADDR; give it"

  "$EXT_DIR/check.sh" upf || die "requirements not met"

  if [ -n "$POD_CIDR" ]; then
    step "Route to the pod network"
    if pod_route_ok; then
      ok "$POD_CIDR is routed: $(ip -4 route show "$POD_CIDR" | head -1)"
    elif pod_route_add; then
      ok "added $POD_CIDR via $NODE_IP — removed again by 'stop'"
    else
      die "no route to $POD_CIDR and --node-ip is not set to add one"
    fi
  fi

  step "UE namespace"
  # ue1's veth carries the gNB's radio link. It is created here rather than with
  # the UE, because the gNB has to be listening on it before a UE looks.
  local ns; ns="$(netns_up 1)" || die "could not create the ue1 namespace"
  ok "$ns  $(ip netns exec "$ns" ip -br addr show "v-${ns}p" | awk '{print $3}') via $GNB_NETNS_ADDR"

  step "gNB"
  if running gnb nr-gnb; then
    "$EXT_DIR/gnb.sh" relink || die "the gNB did not come back up"
  else
    warn "no gNB is running — start one before a UE: '$RUNNER gnb'"
  fi

  step "UPF"
  render
  ok "n3 $UPF_IP on $TRAN, n6 out $N6_DEV, registrar $GW_ADDR:$GW_PORT"
  [ -n "$UPF_BIND" ] && ok "sbi and agent bound to $UPF_BIND"

  if running upf upf; then
    printf '  %-11s %salready running (pid %s)%s\n' upf "$DIM" "$(cat "$(pidfile upf)")" "$OFF"
  else
    nohup "$BIN/upf" -c "$ACTIVE" -v "$LOG_LEVEL" >"$(logfile upf)" 2>&1 &
    echo $! > "$(pidfile upf)"
    sleep 0.5
    running upf upf || {
      rm -f "$(pidfile upf)"
      bad "the UPF failed to start"
      echo "${DIM}$(tail -n 10 "$(logfile upf)" | sed 's/^/      /')${OFF}"
      return 1
    }
    printf '  %-11s started (pid %s)\n' upf "$(cat "$(pidfile upf)")"
  fi

  if wait_url "http://$UPF_IP:$AGENT_PORT/ready" 45; then
    ok "ready — it has pulled its data networks from NSM and opened its N4 gate"
  else
    bad "the UPF did not become ready within 45s"
    note "$(grep -iE 'level=(error|warn)' "$(logfile upf)" | tail -3 | tr '\n' ' ')"
    note "a UPF that registers and then never becomes ready is usually one that"
    note "  cannot reach NSM: NSM is a pod, and its endpoint address is a pod"
    note "  address. Pass --pod-cidr/--node-ip if this host has no route to them."
    return 1
  fi

  # The anchor set is derived, not configured: from the n6 face's DNNs against
  # what NSM declares. Empty means the UPF is up, registered, and will refuse
  # every session — worth saying now rather than at the first UE.
  local anchored
  anchored="$(grep -o 'Anchored data networks: \[[^]]*\]' "$(logfile upf)" | tail -1)"
  case "$anchored" in
    *"[]"*) bad "$anchored"
            note "nothing NSM declares matches this UPF's n6 face. Check --tran against"
            note "  the transport networks in nsm.yaml, and the slices in config/upf.json." ;;
    "")     warn "the log does not say what it anchored — run with --log-level debug" ;;
    *)      ok "$anchored" ;;
  esac

  cmd_show
  echo
  echo "Next: ${BOLD}sudo $RUNNER ue 1${OFF}"
  return 0
}

# What the UPF actually put in the kernel. The log says what it asked for; this
# says what is there, which is the only account that cannot be wrong.
cmd_show() {
  local devname
  devname="$(grep -o '"devName"[[:space:]]*:[[:space:]]*"[^"]*"' "$ACTIVE" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')"
  devname="${devname:-upfgtp}"

  step "What landed in the kernel"
  ip -br addr show "$devname" 2>&1 | sed 's/^/  /'
  ip route show dev "$devname" 2>&1 | sed 's/^/  /'
  local ipt; ipt="$(iptables_bin)" || return 0
  # One MASQUERADE per anchored data network means the rules are there and a
  # data-path failure is somewhere else. "No chain" means the UPF never got a
  # data network from NSM.
  echo "  ${DIM}nat/VOLANTIS-$devname-NAT${OFF}"
  "$ipt" -t nat -S "VOLANTIS-$devname-NAT" 2>&1 | sed 's/^/    /'
  echo "  ${DIM}filter/VOLANTIS-$devname-FWD${OFF}"
  "$ipt" -t filter -S "VOLANTIS-$devname-FWD" 2>&1 | sed 's/^/    /'
  echo "  ${DIM}net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)${OFF}"
}

cmd_stop() {
  need_root "stopping the UPF"
  stop_pid upf
  pod_route_del
  # A UPF that is killed rather than asked to stop leaves its chains behind; a
  # new one does not recognise them as its own, so say so rather than let the
  # next run inherit them.
  local ipt; ipt="$(iptables_bin)" || return 0
  local left; left="$("$ipt" -t nat -S POSTROUTING 2>/dev/null | grep VOLANTIS)"
  [ -n "$left" ] && warn "iptables rules left behind:${left}"
  return 0
}

case "${1:-start}" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  show)  cmd_show ;;
  *)     die "usage: upf.sh [start|stop|show]" ;;
esac
