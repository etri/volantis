#!/usr/bin/env bash
#
# Requirements check for the out-of-cluster components.
#
#   ./deploy/deploy-external.sh check [addresses|db|gnb|upf|ue|all]
#
# Every phase checks its own requirements before it starts anything, so a
# missing kernel module, an occupied port or an unreachable gateway is reported
# by name instead of as a component that comes up and never becomes ready.
#
# Exit status is 0 when the phase can proceed. A warn does not fail it: it is
# something that costs a check or a convenience, not the deployment.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_opts "$@"; save_settings; set -- ${ARGS[@]+"${ARGS[@]}"}

FAILED=0
fail() { bad "$@"; FAILED=1; }

# gtp5g's supported range, checked by the UPF itself at startup: it refuses
# anything outside it rather than failing later in the dataplane.
GTP5G_MIN=0.8.1
GTP5G_MAX=0.9.20
vlt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

check_host() {
  step "Host"
  [ "$(uname -s)" = "Linux" ] \
    && ok "Linux $(uname -r)" \
    || fail "these components are Linux-only (gtp5g and netns both are)"
  command -v ip >/dev/null 2>&1 || fail "iproute2 not found"
  command -v curl >/dev/null 2>&1 \
    && ok "curl" \
    || warn "curl not found — readiness cannot be probed, only liveness"
}

check_addresses() {
  step "The deployment's addresses"
  [ -n "$PRAN_ADDR" ] \
    && ok "pran      $PRAN_ADDR:$PRAN_PORT" \
    || fail "--pran is not set: 'kubectl -n volantis get svc pran-svc' for the EXTERNAL-IP"
  [ -n "$GW_ADDR" ] \
    && ok "gateway   $GW_ADDR:$GW_PORT" \
    || fail "--gateway is not set: 'kubectl -n volantis get svc gateway-svc' for the EXTERNAL-IP"
  ok "database  $DB_URL"

  step "This host's addresses"
  if [ -n "$UPF_IP" ]; then
    ok "upf       $UPF_IP  ${DIM}n3 on $TRAN, and what it advertises for N4${OFF}"
  else
    fail "no source address toward the gateway — set --upf-ip"
  fi
  if [ -n "$GNB_IP" ]; then
    ok "gnb       $GNB_IP  ${DIM}N2 and N3${OFF}"
  else
    fail "no source address toward Proxy-RAN — set --gnb-ip"
  fi

  # nr-gnb and the UPF both want GTP-U/2152, and the port is fixed by TS 29.281
  # in both directions: it is the local bind port *and* the
  # OUTER_HEADER_CREATION_PORT of every downlink tunnel, so it is not
  # configurable and a second address is the only way out. The UPF binds the
  # single address of its n3 face rather than the wildcard, which is what lets
  # the two share a host at all.
  if [ -n "$UPF_IP" ] && [ "$UPF_IP" = "$GNB_IP" ]; then
    fail "the gNB and the UPF would both bind $UPF_IP:$GTPU_PORT"
    note "give them two addresses on this host (--gnb-ip / --upf-ip), or two hosts."
    note "  GTP-U's port is fixed by TS 29.281 and cannot be moved."
  fi

  if [ -n "$N6_DEV" ] && ip link show "$N6_DEV" >/dev/null 2>&1; then
    ok "n6 egress $N6_DEV"
  elif [ -n "$N6_DEV" ]; then
    fail "n6 egress interface $N6_DEV does not exist"
  else
    fail "no default route — cannot tell which interface UE traffic leaves by (--n6-dev)"
  fi
}

check_reachable() {
  step "Reaching the deployment"
  if [ -z "$GW_ADDR" ]; then
    fail "no gateway address to reach"
  elif probe_url "http://$GW_ADDR:$GW_PORT/mon/endpoints"; then
    ok "the gateway answers on $GW_ADDR:$GW_PORT"
  else
    fail "no answer from $GW_ADDR:$GW_PORT/mon/endpoints"
    note "a LoadBalancer EXTERNAL-IP is only reachable while whatever publishes it"
    note "  is running — with minikube that is 'minikube tunnel', in its own"
    note "  terminal, and NOT under sudo (sudo reads /root/.minikube and reports"
    note "  'control plane does not exist')."
  fi

  # The UPF is a mesh consumer as well as a producer: it pulls its data networks
  # from NSM, and an endpoint address is a pod address. A host that can reach
  # the gateway's LoadBalancer address and nothing else gets a UPF that
  # registers, never becomes ready, and anchors nothing.
  if [ -n "$POD_CIDR" ]; then
    if pod_route_ok; then
      ok "pod network $POD_CIDR is routed"
    elif [ -n "$NODE_IP" ]; then
      warn "no route to $POD_CIDR — 'upf start' adds it via $NODE_IP"
    else
      fail "no route to $POD_CIDR and no --node-ip to add one"
    fi
  else
    note "--pod-cidr is not set. If the cluster's pod network is not routable from"
    note "  this host the UPF will register and then never become ready. minikube"
    note "  with 'minikube tunnel' is exactly that case: 10.244.0.0/16 via the node."
  fi
}

check_db() {
  step "Subscription database"
  if (exec 3<>"/dev/tcp/$DB_ADDR/$DB_PORT") 2>/dev/null; then
    ok "answers on $DB_ADDR:$DB_PORT"
  else
    fail "nothing is listening on $DB_ADDR:$DB_PORT"
    note "the database is ClusterIP by design — only the PCF and the UDM read it —"
    note "  so provisioning goes through a port-forward:"
    note "  kubectl -n volantis port-forward svc/udr-mongo $DB_PORT:27017"
  fi
}

check_binaries() {
  step "Binaries in ${BIN#$ROOT/}"
  local missing=() b
  for b in "$@"; do [ -x "$BIN/$b" ] || missing+=("$b"); done
  [ ${#missing[@]} -eq 0 ] && ok "${*} present" || {
    fail "missing: ${missing[*]}"
    note "see bin/README.md — download the binary bundle and unpack it here"
  }
  [ -x "$BIN/gtp5g-tunnel" ] \
    || note "bin/gtp5g-tunnel absent — a user-plane run cannot dump the kernel's own rule set; bin/README.md builds it"
}

check_ueransim() {
  step "UERANSIM"
  local d
  if ! d="$(ueransim_dir)"; then
    fail "nr-gnb not found"
    note "clone and build UERANSIM (https://github.com/aligungr/UERANSIM), then either"
    note "  copy nr-gnb/nr-ue/nr-cli into bin/, put its build/ directory on PATH, or"
    note "  export UERANSIM=/path/to/UERANSIM/build. bin/README.md has all three."
    return
  fi
  local missing=() b
  for b in nr-gnb nr-ue nr-cli; do [ -x "$d/$b" ] || missing+=("$b"); done
  [ ${#missing[@]} -eq 0 ] && ok "$d" || fail "$d is missing: ${missing[*]}"
}

check_upf() {
  step "User plane"
  [ "$(id -u)" = "0" ] \
    && ok "running as root" \
    || fail "the UPF needs root: it creates a gtp5g netdev, a route and iptables rules"

  local v
  if [ -r /sys/module/gtp5g/version ]; then
    v="$(cat /sys/module/gtp5g/version)"
    if vlt "$v" "$GTP5G_MIN"; then
      fail "gtp5g $v is below $GTP5G_MIN — the UPF refuses it at startup"
    elif ! vlt "$v" "$GTP5G_MAX"; then
      fail "gtp5g $v is $GTP5G_MAX or newer — the UPF refuses it at startup"
    else
      ok "gtp5g $v"
    fi
  else
    fail "the gtp5g kernel module is not loaded"
    note "build it from https://github.com/free5gc/gtp5g (>=$GTP5G_MIN, <$GTP5G_MAX), then 'modprobe gtp5g'"
  fi

  local ipt
  if ipt="$(iptables_bin)"; then
    ok "iptables at $ipt"
  else
    fail "iptables not found in PATH, /sbin or /usr/sbin"
    note "config/upf.json sets firewall.manage, so the UPF installs its own rules and needs it"
  fi

  if [ -n "$UPF_IP" ] && port_free udp "$UPF_IP" "$GTPU_PORT"; then
    ok "GTP-U $GTPU_PORT free on $UPF_IP"
  elif [ -n "$UPF_IP" ]; then
    fail "GTP-U $UPF_IP:$GTPU_PORT is already bound"
    note "a UPF left from an earlier run, or the gNB — the two need separate addresses"
    ss -lnup 2>/dev/null | awk -v a="$UPF_IP:$GTPU_PORT" '$0 ~ a {print "         " $0}'
  fi
  [ -n "$GNB_IP" ] && ! port_free udp "$GNB_IP" "$GTPU_PORT" \
    && note "$GNB_IP:$GTPU_PORT is held by the gNB's N3 — expected, and not a clash"

  [ -w /proc/sys/net/ipv4/ip_forward ] \
    && ok "net.ipv4.ip_forward is writable" \
    || fail "cannot write net.ipv4.ip_forward — the UPF forwards nothing without it"
}

check_ue() {
  step "UE"
  [ "$(id -u)" = "0" ] \
    && ok "running as root" \
    || fail "a UE runs in its own network namespace, which needs root"

  local n=0 f
  for f in "$UEDIR"/ue-*.yaml; do [ -f "$f" ] && n=$((n + 1)); done
  [ "$n" -gt 0 ] \
    && ok "$n provisioned profile(s) in ${UEDIR#$ROOT/}" \
    || fail "no UE profiles — '$RUNNER subscribers' provisions them"

  probe_url "http://$UPF_IP:$AGENT_PORT/ready" \
    && ok "the UPF is ready" \
    || warn "no UPF is ready — the UE will register and its PDU session will be refused"

  if [ -n "$PROBE_TARGET" ]; then
    if ping -c 1 -W 2 -q "$PROBE_TARGET" >/dev/null 2>&1; then
      ok "probe target $PROBE_TARGET answers from this host"
    else
      warn "probe target $PROBE_TARGET does not answer from the host itself"
      note "a target the host cannot reach fails identically to a dead tunnel"
    fi
  else
    note "set --probe to an address this host can reach, to test the data path."
    note "  Do not use 8.8.8.8 blindly: a network that blocks ICMP to it looks"
    note "  exactly like a broken tunnel."
  fi
}

phase="${1:-all}"
case "$phase" in
  addresses) check_host; check_addresses; check_reachable ;;
  db)        check_db ;;
  gnb)       check_addresses; check_ueransim ;;
  upf)       check_binaries upf; check_addresses; check_reachable; check_upf ;;
  ue)        check_ueransim; check_ue ;;
  all)       check_host; check_addresses; check_reachable; check_db
             check_binaries upf uegen; check_ueransim
             step "User plane"
             note "run 'sudo $RUNNER check upf' for the root-only checks"
             note "  (gtp5g, iptables, GTP-U)" ;;
  # Everything, root-only checks included. This is what `e2e` runs first, so
  # that a missing kernel module is reported as a requirement rather than as a
  # user plane that comes up and anchors nothing.
  e2e)       check_host; check_addresses; check_reachable; check_db
             check_binaries upf uegen; check_ueransim; check_upf ;;
  *)         die "unknown phase '$phase' — one of: addresses db gnb upf ue all e2e" ;;
esac

echo
if [ "$FAILED" = "0" ]; then
  echo "${GREEN}Requirements met${OFF} for '$phase'."
else
  echo "${RED}Requirements not met${OFF} for '$phase' — fix the FAIL lines above."
fi
exit "$FAILED"
