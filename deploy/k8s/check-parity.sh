#!/usr/bin/env bash
#
# check-parity.sh — prove the Helm chart and the kustomize manifests describe
#                   the same deployment.
#
# There are two copies of every deployment here: manifest/<deployment>/, applied
# with `kubectl apply -k`, and helm/, installed as a release. Two copies of one
# thing drift. This is what makes that drift visible instead of waiting for a
# cluster to disagree with a README.
#
# It compares *semantics*, not text. Both renderings are parsed, every JSON
# document embedded in them is decoded — the NF configuration in each ConfigMap
# and the service definition in each routing annotation — so that key order is
# not a difference, the documents are sorted, and the two are diffed. Comments
# survive neither renderer and are out of scope, which is one more reason the
# manifests stay hand-written.
#
# Run it from anywhere:
#   ./deploy/k8s/check-parity.sh              # single-cloud
#   ./deploy/k8s/check-parity.sh -d multi     # central, edge1 and edge2
#   ./deploy/k8s/check-parity.sh -d all       # every cloud of both
#
# Exit 0 if they agree, 1 if they do not, 2 if something could not be run.
# Requires: helm, kubectl (its built-in kustomize), python3 with PyYAML.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT="single"
VERBOSE=0

usage() {
  cat <<'EOF'
Usage: ./deploy/k8s/check-parity.sh [options]

Options:
  -d, --deployment WHICH  single | multi | all   (default: single)
  -v, --verbose           print both normalised renderings on failure
  -h, --help              show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--deployment) DEPLOYMENT="${2:-}"; shift 2 ;;
    -v|--verbose)    VERBOSE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1" ;;
  esac
done

command -v helm    >/dev/null || die "helm is not installed"
command -v kubectl >/dev/null || die "kubectl is not installed"
command -v python3 >/dev/null || die "python3 is not installed"
python3 -c 'import yaml' 2>/dev/null || die "python3 has no PyYAML (pip3 install PyYAML)"

# Which clouds to compare, and for each: the manifest directory and the values
# file the chart needs to describe it. single-cloud is the chart's defaults and
# has no values file.
declare -a clouds=()
declare -A cloud_base=() cloud_values=()

add() {
  local name="$1" base="$2" values="${3:-}"
  [[ -d "$base" ]] || die "no such deployment directory: $base"
  [[ -z "$values" || -f "$values" ]] || die "no such values file: $values"
  clouds+=( "$name" )
  cloud_base["$name"]="$base"
  cloud_values["$name"]="$values"
}

add_single() { add "single-cloud" "${HERE}/manifest/single-cloud" ""; }
add_multi() {
  local c
  for c in central edge1 edge2; do
    add "$c" "${HERE}/manifest/multi-cloud/${c}" "${HERE}/helm/values/${c}.yaml"
  done
}

case "$DEPLOYMENT" in
  single)          add_single ;;
  multi|multi-cloud) add_multi ;;
  all)             add_single; add_multi ;;
  *) die "--deployment must be 'single', 'multi' or 'all', not '$DEPLOYMENT'" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Normalise a rendering to a stable, comparable form:
#   * drop empty documents, and the labels Helm charts conventionally stamp on
#     resources (this one does not, but a future one might)
#   * decode every JSON document carried as a string — a ConfigMap's .json
#     entries and a service definition's routing annotation — so that the
#     hand-written key order in the manifests and Go's sorted order from
#     toPrettyJson are the same object rather than two different strings
#   * sort documents by identity, and every key within them
normalise() {
  python3 - "$1" <<'PYEOF'
import json, sys, yaml

HELM_LABELS = ("app.kubernetes.io/managed-by", "helm.sh/chart",
               "app.kubernetes.io/instance", "app.kubernetes.io/version")
JSON_ANNOTATIONS = ("mesh.volantis.io/definition",)

def decode(where, key, val):
    try:
        return json.loads(val)
    except json.JSONDecodeError as exc:
        sys.exit("%s: %s is not valid JSON: %s" % (where, key, exc))

def clean(doc):
    md = doc.get("metadata") or {}
    name = "%s/%s" % (doc.get("kind"), md.get("name"))
    md.pop("creationTimestamp", None)
    for k in HELM_LABELS:
        (md.get("labels") or {}).pop(k, None)
    if md.get("labels") == {}:
        md.pop("labels")
    ann = md.get("annotations") or {}
    for key in JSON_ANNOTATIONS:
        if key in ann and isinstance(ann[key], str):
            ann[key] = decode(name, key, ann[key])
    if ann == {}:
        md.pop("annotations", None)
    data = doc.get("data") or {}
    for key, val in list(data.items()):
        if key.endswith(".json") and isinstance(val, str):
            data[key] = decode(name, key, val)
    return doc

def ident(doc):
    md = doc.get("metadata") or {}
    return (doc.get("kind", ""), md.get("namespace", ""), md.get("name", ""),
            doc.get("apiVersion", ""))

with open(sys.argv[1]) as fh:
    docs = [clean(d) for d in yaml.safe_load_all(fh) if d]

seen = {}
for d in docs:
    key = ident(d)
    if key in seen:
        sys.exit("duplicate resource in one rendering: %s" % (key,))
    seen[key] = d

print(json.dumps([seen[k] for k in sorted(seen)], indent=2, sort_keys=True))
PYEOF
}

count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$1"; }

failed=()
for c in "${clouds[@]}"; do
  base="${cloud_base[$c]}"
  # A chart cannot own the namespace it installs into, so `namespace.create` is
  # off for an install. Render it here, or the manifests' namespace.yaml would
  # read as a resource the chart is missing.
  # Two knobs are mechanism rather than deployment, and are normalised here so
  # that the comparison is about what gets deployed:
  #
  #   namespace.create  a chart cannot own the namespace it installs into, so it
  #                     is off for an install, while the manifests carry a
  #                     Namespace of their own.
  #   image.*           the manifests carry the bare names that a kustomize
  #                     overlay rewrites at apply time; the chart names the
  #                     published images directly, having no overlay step.
  declare -a vargs=(
    --set namespace.create=true
    --set image.prefix=volantis --set image.tag=latest
  )
  [[ -n "${cloud_values[$c]}" ]] && vargs+=( -f "${cloud_values[$c]}" )

  helm template volantis "${HERE}/helm" --namespace volantis "${vargs[@]}" \
    > "${TMP}/${c}.helm.yaml" || die "$c: helm template failed"
  kubectl kustomize "$base" > "${TMP}/${c}.kustomize.yaml" \
    || die "$c: kustomize render failed"

  normalise "${TMP}/${c}.kustomize.yaml" > "${TMP}/${c}.kustomize.json" || exit 2
  normalise "${TMP}/${c}.helm.yaml"      > "${TMP}/${c}.helm.json"      || exit 2

  printf '%-14s %-42s %2s resources  ' \
    "$c" "${base#"${HERE}"/}" "$(count "${TMP}/${c}.kustomize.json")"

  if diff -u --label "manifest:${c}" "${TMP}/${c}.kustomize.json" \
             --label "helm:${c}"     "${TMP}/${c}.helm.json" > "${TMP}/${c}.diff"; then
    echo "OK"
  else
    echo "DRIFT"
    failed+=( "$c" )
  fi
done

if (( ${#failed[@]} == 0 )); then
  echo
  echo "the chart and the manifests render the same deployment"
  exit 0
fi

for c in "${failed[@]}"; do
  echo
  echo "==> ${c}: the two renderings differ"
  cat "${TMP}/${c}.diff"
  if (( VERBOSE )); then
    echo "--> manifests, normalised"; cat "${TMP}/${c}.kustomize.json"
    echo "--> chart, normalised";     cat "${TMP}/${c}.helm.json"
  fi
done
exit 1
