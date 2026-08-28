#!/usr/bin/env bash
#
# nr-cli against a running UERANSIM node.
#
#   ./deploy/deploy-external.sh cli               list the nodes
#   ./deploy/deploy-external.sh cli gnb           an interactive console on the gNB
#   sudo ./deploy/deploy-external.sh cli ue 1     an interactive console on UE 1
#
# A node with no command after it gets nr-cli's interactive console, with its
# own prompt, history and `commands`. Append a command instead and it runs that
# one and exits, which is the form a script wants:
#
#   ./deploy/deploy-external.sh cli gnb ue-list
#   sudo ./deploy/deploy-external.sh cli ue 1 ps-list
#
# This exists because nr-cli's two halves disagree about network namespaces.
# Discovery is a directory in /tmp — /tmp/UERANSIM.proc-table — which every
# namespace shares, so `nr-cli -d` lists a UE from the host and looks like it
# will work. The command channel is a loopback socket, and loopback is
# per-namespace, so a command issued from the host reaches nothing: nr-cli
# waits for a reply that cannot come and hangs with no error and no timeout.
# The gNB runs in the host's namespace and the UEs each run in their own, so
# the right namespace is a property of the node, not something to remember.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# No save_settings: this is told nothing about the deployment and reads only
# what is already running, so it has nothing to remember and never needs to
# write into a run directory a root shot may own.
parse_opts "$@"; set -- ${ARGS[@]+"${ARGS[@]}"}

UERANSIM_DIR="$(ueransim_dir)" || die "nr-cli not found — see '$RUNNER check gnb'"
NRCLI="$UERANSIM_DIR/nr-cli"
[ -x "$NRCLI" ] || die "no $NRCLI"

# The nodes nr-cli can see. Namespace-independent, being a directory listing.
nodes() { "$NRCLI" -d 2>/dev/null; }

# The gNB's node name is built from its PLMN and gNB id, so read it back rather
# than reconstructing it from the configuration.
gnb_node() { nodes | grep -m1 '^UERANSIM-gnb-'; }

# A UE's node name is its SUPI, which is in the profile uegen provisioned.
ue_node() { awk '/^supi:/ {print $2; exit}' "$UEDIR/ue-$1.yaml" 2>/dev/null; }

# Which ue-N.yaml provisioned a SUPI, so the listing can say which number to
# pass instead of leaving the reader to match SUPIs by eye.
ue_number() {
  local f n
  for f in "$UEDIR"/ue-*.yaml; do
    [ -f "$f" ] || continue
    [ "$(awk '/^supi:/ {print $2; exit}' "$f")" = "$1" ] || continue
    n="$(basename "$f" .yaml)"; echo "${n#ue-}"; return 0
  done
  return 1
}

# run <netns|""> <node> [command...]
run() {
  local ns="$1" node="$2"; shift 2
  local pre=()
  [ -n "$ns" ] && pre=(ip netns exec "$ns")

  # An interactive shell is handed the terminal and this script is done.
  [ $# -eq 0 ] && exec "${pre[@]}" "$NRCLI" "$node"

  # `cli ue 1 -e status` and `cli ue 1 status` mean the same thing.
  case "$1" in -e|--exec) shift ;; esac
  [ $# -gt 0 ] || exec "${pre[@]}" "$NRCLI" "$node"

  # Bounded, unlike nr-cli itself. Every node command answers immediately, so
  # waiting means the node is wedged rather than busy — and an unbounded wait
  # is the failure this script is here to prevent.
  "${pre[@]}" timeout 20 "$NRCLI" "$node" -e "$*"
  local rc=$?
  if [ "$rc" = 124 ]; then
    bad "no reply from $node within 20s"
    note "the node is registered in the proc table but its command socket is not"
    note "  answering — it has died without cleaning up, or it is wedged."
    note "  '$RUNNER status' says what is actually running."
  fi
  return "$rc"
}

cmd_list() {
  local all name num
  all="$(nodes)"
  step "Nodes nr-cli can see"
  if [ -z "$all" ]; then
    warn "none — nothing is running"
    note "'$RUNNER gnb' starts the gNB, 'sudo $RUNNER ue 1' a UE"
    return 1
  fi
  while read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      UERANSIM-gnb-*)
        printf '  %-22s %-5s %s\n' "$name" "gnb" "${DIM}$RUNNER cli gnb${OFF}" ;;
      *)
        num="$(ue_number "$name")" \
          && printf '  %-22s %-5s %s\n' "$name" "ue" "${DIM}sudo $RUNNER cli ue $num${OFF}" \
          || printf '  %-22s %-5s %s\n' "$name" "ue" "${DIM}not one of this run's profiles${OFF}" ;;
    esac
  done <<< "$all"
  echo
  note "those open an interactive console. Append a command — 'cli gnb ue-list' —"
  note "  to run one and exit; 'commands' inside the console lists them."
  return 0
}

cmd_gnb() {
  local node; node="$(gnb_node)"
  [ -n "$node" ] || die "no gNB is running — '$RUNNER gnb' starts one"
  run "" "$node" "$@"
}

cmd_ue() {
  local n="$1"; shift
  local ns="ue$n" supi
  supi="$(ue_node "$n")"
  [ -n "$supi" ] || die "no ${UEDIR#$ROOT/}/ue-$n.yaml — '$RUNNER subscribers' provisions them"
  nodes | grep -qx "$supi" || die "$supi is not running — 'sudo $RUNNER ue $n' starts it"
  # Checked before the root demand, so "that UE is not running" is not reported
  # as "you forgot sudo".
  ip netns list 2>/dev/null | grep -qw "$ns" || die "no $ns namespace, but $supi is running — started outside this runner?"
  need_root "reaching into the $ns namespace, which is where that UE's command socket is"
  run "$ns" "$supi" "$@"
}

case "${1:-list}" in
  list|"") cmd_list ;;
  gnb)     shift; cmd_gnb "$@" ;;
  ue)      shift
           n="${1:-1}"; case "$n" in ''|*[!0-9]*) n=1 ;; *) shift ;; esac
           cmd_ue "$n" "$@" ;;
  *)       die "usage: cli.sh [list | gnb [command...] | ue <n> [command...]]" ;;
esac
