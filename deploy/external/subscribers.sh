#!/usr/bin/env bash
#
# Subscribers, and the UE profiles that match them.
#
#   ./deploy/deploy-external.sh subscribers [provision [n] | list] --db URL
#
# There is no UDR network function yet: subscriber data goes straight into
# MongoDB, and `uegen` is what writes it. It is a client of the same provisioning
# code udrweb's API runs, so the CLI and the API cannot disagree about what a
# subscriber is.
#
# The database is ClusterIP in every deployment here — deliberately, since only
# the PCF and the UDM read it and both are central — so --db is normally a
# port-forward on loopback:
#
#   kubectl -n volantis port-forward svc/udr-mongo 27017:27017
#
# Two flags this pins down that are easy to get wrong by hand:
#
#   -template   without it uegen falls back to a built-in profile that points
#               gnbSearchList at an address no gNB holds and leaves `sessions`
#               empty, so the UE registers and never asks for a PDU session.
#   -seed       makes the batch reproducible. Re-running provisions the same
#               subscribers rather than piling up new ones, so this is safe to
#               call on every start.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_opts "$@"; save_settings; set -- ${ARGS[@]+"${ARGS[@]}"}

TEMPLATE="$CFG/ueransim/ue.yaml"
ACTIVE="$GENDIR/uegen.json"

render() {
  mkdirs
  sed "s|DB_URL|$DB_URL|" "$CFG/uegen.json" > "$ACTIVE"
}

uegen() { "$BIN/uegen" -c "$ACTIVE" "$@"; }

cmd_provision() {
  local n="${1:-$NUM_UES}"
  [ -x "$BIN/uegen" ] || die "no $BIN/uegen — see bin/README.md"
  render

  if ! (exec 3<>"/dev/tcp/$DB_ADDR/$DB_PORT") 2>/dev/null; then
    bad "nothing answers at $DB_ADDR:$DB_PORT"
    note "the database is ClusterIP, so it needs a port-forward:"
    note "  kubectl -n volantis port-forward svc/udr-mongo $DB_PORT:27017"
    return 1
  fi

  # init creates the collections and their indexes. It is idempotent; only
  # -reset destroys anything, and this never passes it.
  uegen init >/dev/null || die "uegen init failed"
  uegen gen -seed "$UE_SEED" -n "$n" -d "$UEDIR" -p "ue-" -template "$TEMPLATE" \
    | sed 's/^/  /' || die "uegen gen failed"
  ok "$(ls "$UEDIR"/ue-*.yaml 2>/dev/null | wc -l) profile(s) in ${UEDIR#$ROOT/}, subscribers in $DB_URL"
}

case "${1:-provision}" in
  provision) shift 2>/dev/null; cmd_provision "${1:-}" ;;
  list)      render; uegen list ;;
  *)         die "usage: subscribers.sh [provision [n] | list]" ;;
esac
