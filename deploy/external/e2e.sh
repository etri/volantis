#!/usr/bin/env bash
#
# The end-to-end test, against an already-running deployment.
#
#   sudo ./deploy/deploy-external.sh e2e --pran ADDR --gateway ADDR [--probe ADDR]
#
# It drives the whole path a UE takes and reports on each stage separately, so
# that a failure names the stage it happened in rather than "the UE did not get
# an address":
#
#   subscribers  written into the database, with profiles to match
#   NG Setup     the gNB's SCTP association to Proxy-RAN
#   N4           the UPF registered, configured by NSM, and anchoring something
#   registration 5G-AKA over SUCI, the DAMF handing the UE to an AMF
#   PDU session  the SMF's four decisions, and a tunnel in the kernel
#   data path    traffic actually crossing that tunnel, counted at both ends
#
# Root, because two of those stages are: the UPF creates a gtp5g netdev and
# writes iptables rules, and each UE runs in its own network namespace.
#
# Nothing is torn down at the end. A failed stage is worth looking at, and the
# logs under deploy/run/external/log/ are where it is; 'stop' when finished.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_opts "$@"; save_settings; set -- ${ARGS[@]+"${ARGS[@]}"}

need_root "the end-to-end test (the UPF and the UE namespaces both need it)"

STAGES=(); RESULTS=()
stage() { STAGES+=("$1"); RESULTS+=("$2"); }

run_stage() {
  local name="$1"; shift
  step "$name"
  if "$@"; then stage "$name" pass; return 0; fi
  stage "$name" FAIL; return 1
}

step "What this is being run against"
print_settings

run_stage "Requirements"  "$EXT_DIR/check.sh" e2e        || exit 1
run_stage "Subscribers"   "$EXT_DIR/subscribers.sh" provision "$NUM_UES" || exit 1
run_stage "NG Setup"      "$EXT_DIR/gnb.sh" start        || exit 1
run_stage "N4"            "$EXT_DIR/upf.sh" start        || exit 1
# The UPF's start relinks the gNB onto ue1's veth, so the association the UE
# attaches through is a different one from the one NG Setup was checked on.
run_stage "Registration and PDU session" "$EXT_DIR/ue.sh" start 1 || exit 1

if [ -n "$PROBE_TARGET" ]; then
  run_stage "Data path" "$EXT_DIR/ue.sh" probe 1
else
  step "Data path"
  warn "skipped — pass --probe with an address this host can reach"
  note "the tunnel exists either way; whether it carries anything is what this"
  note "  stage would have shown"
  stage "Data path" skipped
fi

step "Errors in this run's logs"
errs="$(grep -h 'level=error' "$LOGDIR"/upf.log 2>/dev/null | head -5)"
[ -n "$errs" ] && echo "$errs" | sed 's/^/  /' || ok "none from the UPF"

step "Verdict"
failed=0
for i in "${!STAGES[@]}"; do
  case "${RESULTS[$i]}" in
    pass)    printf '  %s%-7s%s %s\n' "$GREEN" "pass"    "$OFF" "${STAGES[$i]}" ;;
    skipped) printf '  %s%-7s%s %s\n' "$YELLOW" "skipped" "$OFF" "${STAGES[$i]}" ;;
    *)       printf '  %s%-7s%s %s\n' "$RED" "FAIL"    "$OFF" "${STAGES[$i]}"; failed=1 ;;
  esac
done
echo
echo "${DIM}Logs in ${LOGDIR#$ROOT/}. Still running — 'sudo $RUNNER stop' when finished.${OFF}"
exit "$failed"
