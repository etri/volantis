#!/usr/bin/env bash
#
# Requirements check for the single-machine deployment.
#
#   ./deploy/deploy-local.sh check [core|cpup]
#
# The control plane's requirements, and whether it is serving. The gNB, the UPF
# and the UE phases are not here: those components are deploy/external/'s, and
# so are their checks — ../deploy-local.sh routes `check gnb|upf|ue` there with
# this deployment's addresses.
#
# Every phase of the deployment checks its own requirements before it starts
# anything, so a missing kernel module or an occupied port is reported by name
# instead of as a component that comes up and never becomes ready. This is that
# check, and it is also runnable on its own.
#
# Exit status is 0 when the phase can proceed. A warn does not fail it: it is
# something that costs you a check or a convenience, not the deployment.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAILED=0
fail() { bad "$@"; FAILED=1; }

check_host() {
  step "Host"
  [ "$(uname -s)" = "Linux" ] \
    && ok "Linux $(uname -r)" \
    || fail "this deployment is Linux-only (gtp5g, netns and 127.0.0.0/8 all assume it)"

  if ip -4 addr show dev lo 2>/dev/null | grep -q '127.0.0.1/8'; then
    ok "127.0.0.0/8 is local — the whole address plan needs no setup"
  else
    fail "lo does not carry 127.0.0.0/8; every address in the plan has to be added by hand"
  fi

  command -v curl >/dev/null 2>&1 \
    && ok "curl" \
    || warn "curl not found — readiness cannot be probed, only liveness"
  command -v jq >/dev/null 2>&1 || note "jq not found — the mesh views print unformatted"
}

check_binaries() {
  local missing=() b
  step "Binaries in ${BIN#$ROOT/}"
  # The UPF is not here: deploy/external/ checks for it, because it is the same
  # binary a cluster deployment runs outside the cluster.
  local want=(controller gateway nsm udm ausf pcf damf amf smf pran uegen)
  for b in "${want[@]}"; do
    [ -x "$BIN/$b" ] || missing+=("$b")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    ok "all ${#want[@]} present"
  else
    fail "missing: ${missing[*]}"
    note "see bin/README.md — download the binary bundle and unpack it here"
  fi
}

check_configs() {
  step "Configuration in ${CFG#$ROOT/}"
  local missing=() c
  for c in controller gateway nsm udm ausf pcf damf amf smf pran; do
    [ -f "$CFG/$c.json" ] || missing+=("$c.json")
  done
  [ ${#missing[@]} -eq 0 ] && ok "all present" || fail "missing: ${missing[*]}"
}

check_mongo() {
  step "Subscriber store"
  if (exec 3<>"/dev/tcp/$MONGO_ADDR/$MONGO_PORT") 2>/dev/null; then
    ok "MongoDB answers on $MONGO_ADDR:$MONGO_PORT"
  else
    fail "nothing is listening on $MONGO_ADDR:$MONGO_PORT"
    note "Volantis has no UDR: UDM, PCF and SMF read subscribers from MongoDB directly."
    note "  docker run -d -p 27017:27017 --name volantis-mongo mongo"
  fi
}

check_sctp() {
  step "Kernel SCTP"
  # Proxy-RAN terminates NGAP over SCTP. The module autoloads when the socket
  # is created, so being absent from lsmod says nothing — being absent from
  # both lsmod and /lib/modules does.
  if grep -qi 'sctp' /proc/net/protocols 2>/dev/null; then
    ok "SCTP is available"
  elif ls "/lib/modules/$(uname -r)/kernel/net/sctp/sctp.ko"* >/dev/null 2>&1; then
    ok "SCTP module present, loads on first use"
  else
    fail "no SCTP support — Proxy-RAN cannot listen on $PRAN_ADDR:$NGAP_PORT"
    note "install the kernel's extra modules package, or 'modprobe sctp'"
  fi
}

check_ports() {
  step "Ports"
  local busy=() spec addr port proto
  for spec in "tcp $CTRL_ADDR $CTRL_PORT" "tcp $GW_ADDR $GW_PORT" \
              "tcp $NSM_ADDR $SBI_PORT" "tcp $PCF_ADDR $SBI_PORT" \
              "tcp $AUSF_ADDR $SBI_PORT" "tcp $UDM_ADDR $SBI_PORT" \
              "tcp $DAMF_ADDR $SBI_PORT" "tcp $PRAN_ADDR $SBI_PORT" \
              "tcp $AMF_ADDR $SBI_PORT" "tcp $SMF_ADDR $SBI_PORT" \
              "sctp $PRAN_ADDR $NGAP_PORT"; do
    set -- $spec; proto="$1"; addr="$2"; port="$3"
    port_free "$proto" "$addr" "$port" || busy+=("$addr:$port/$proto")
  done
  if [ ${#busy[@]} -eq 0 ]; then
    ok "every address in the plan is free"
  else
    fail "already in use: ${busy[*]}"
    note "an earlier run that did not stop cleanly — './deploy/deploy-local.sh stop' first"
  fi
}



# Whether the control plane is actually serving. `deploy-local.sh upf` runs this
# before starting the user plane: the UPF pulls its data networks from NSM
# before it opens N4, so a control plane that is not up yet shows up several
# minutes later as a UPF that registered and never became ready.
check_control_plane_up() {
  step "Control plane"
  local down=() spec name url
  for spec in "nsm $NSM_ADDR" "udm $UDM_ADDR" "ausf $AUSF_ADDR" "pcf $PCF_ADDR" \
              "damf $DAMF_ADDR" "amf $AMF_ADDR" "smf $SMF_ADDR" "pran $PRAN_ADDR"; do
    set -- $spec; name="$1"
    probe "http://$2:$AGENT_PORT/ready" || down+=("$name")
  done
  if [ ${#down[@]} -eq 0 ]; then
    ok "every network function is ready"
  else
    fail "not ready: ${down[*]}"
    note "'./deploy/deploy-local.sh start' first, then './deploy/deploy-local.sh status'"
  fi
}


phase="${1:-core}"
case "$phase" in
  core) check_host; check_binaries; check_configs; check_mongo; check_sctp; check_ports ;;
  cpup) check_control_plane_up ;;
  *)    die "unknown phase '$phase' — one of: core cpup. The gNB, UPF and UE"\
          " checks are deploy/external/check.sh's: './deploy/deploy-local.sh check $phase'" ;;
esac

echo
if [ "$FAILED" = "0" ]; then
  echo "${GREEN}Requirements met${OFF} for '$phase'."
else
  echo "${RED}Requirements not met${OFF} for '$phase' — fix the FAIL lines above."
fi
exit "$FAILED"
