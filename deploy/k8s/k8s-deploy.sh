#!/usr/bin/env bash
#
# k8s-deploy.sh — apply a Volantis deployment to Kubernetes, pinned to one
#                 image tag.
#
# The manifests under manifest/ name no registry. This script does not edit
# them: it generates a kustomize overlay under manifest/.deploy/ that rewrites
# every image to <IMAGE>-<nf>:<TAG>, and applies that instead. With --engine
# helm it passes the same two values to the chart.
#
# Run it from the repository root:
#   ./deploy/k8s/k8s-deploy.sh [options]
#
# Requires: kubectl (its built-in kustomize; v1.21+).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${HERE}/manifest"
OVERLAY_ROOT="${DEPLOY_DIR}/.deploy"
HELM_DIR="${HERE}/helm"

# Where the images are pulled from. Fixed: this is where the project publishes,
# the packages are public, and pulling them needs no registry account. Change it
# here to deploy from a mirror or a build of your own — it is the only place an
# image prefix is written, and no manifest carries one.
IMAGE="ghcr.io/reogac/volantis"

# What the manifests literally call the images. Not a destination and not
# configurable: it is the kustomize transformer's match key, and the manifests
# are part of this repository.
LOCAL_NAME="volantis"

TAG="v0.1.1"
NAMESPACE="volantis"

DEPLOYMENT="single"
CLOUD_ARG=""
# Which renderer applies the deployment. `kustomize` is the manifests as
# they stand; `helm` installs the chart as a release, which is what gives
# `helm uninstall` something precise to remove. Both describe the same
# deployment and check-parity.sh is what proves it.
ENGINE="kustomize"
RELEASE="volantis"
CONTEXT=""
LOCAL=0
WAIT=0
WAIT_TIMEOUT="600s"
DELETE=0
DRY_RUN=0
ASSUME_YES=0
PRINT_HOSTS=0
NO_HOSTS=0

usage() {
  cat <<'EOF'
Usage: ./deploy/k8s/k8s-deploy.sh [options]

Applies a Volantis deployment with every volantis-<nf> image pointed at
ghcr.io/reogac/volantis-<nf>:<tag>. To pull from a registry of your own, edit
IMAGE at the top of this script.

Options:
  -t, --tag TAG           image version to deploy  (default: v0.1.1)
  -d, --deployment WHICH  single | multi          (default: single)
      --engine WHICH      kustomize | helm        (default: kustomize)
                          helm installs the chart in deploy/k8s/helm as a
                          release, one per cluster
  -c, --cloud LIST        multi only: which clouds, comma- or space-separated.
                          An entry may name its kube context: central=kind-central
                          (default: central,edge1,edge2)
      --context NAME      kube context for every cloud without its own
  -w, --wait              after applying, wait for the workloads to come up
      --timeout DURATION  how long -w waits per cloud (default: 600s)
  -D, --delete            kubectl delete instead of apply
      --print-hosts       print this deployment's name->address mapping in
                          hosts(5) form, for the UPF machines, and exit
      --no-hosts          do not inject hostAliases, even if dns-hosts has
                          entries (use when real DNS serves the names)
  -n, --dry-run           render, show the images and the diff, change nothing
  -y, --yes               skip the confirmation prompt
  -h, --help              show this help

Examples, from the repository root:
  ./deploy/k8s/k8s-deploy.sh -n              # what the default tag would do
  ./deploy/k8s/k8s-deploy.sh -t v0.2.0       # single cloud, pinned to v0.2.0
  ./deploy/k8s/k8s-deploy.sh --engine helm -t v0.2.0
  ./deploy/k8s/k8s-deploy.sh --engine helm -d multi -c edge1=kind-edge1 -t v0.2.0
  ./deploy/k8s/k8s-deploy.sh -d multi -t v0.2.0
  ./deploy/k8s/k8s-deploy.sh -d multi -c central=kind-central -t v0.2.0
  ./deploy/k8s/k8s-deploy.sh -D -d multi -c edge2 -t v0.2.0
  ./deploy/k8s/k8s-deploy.sh -d multi --print-hosts >> /etc/hosts
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag)        TAG="${2:-}"; shift 2 ;;
    -d|--deployment) DEPLOYMENT="${2:-}"; shift 2 ;;
    --engine)        ENGINE="${2:-}"; shift 2 ;;
    -c|--cloud)      CLOUD_ARG="${2:-}"; shift 2 ;;
    --context)       CONTEXT="${2:-}"; shift 2 ;;
    --timeout)       WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    # Undocumented on purpose: -l applies the manifests with the names they
    # carry, so a freshly built image already in the node's runtime is used
    # as-is. That is for testing an unpublished build in the lab, not a way to
    # deploy this repo, and it is deliberately absent from usage() and from
    # every README.
    -l|--local)      LOCAL=1; shift ;;
    -w|--wait)       WAIT=1; shift ;;
    -D|--delete)     DELETE=1; shift ;;
    --print-hosts)   PRINT_HOSTS=1; shift ;;
    --no-hosts)      NO_HOSTS=1; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              die "unknown option: $1" ;;
    *)               die "unexpected argument: $1 (a tag goes after -t)" ;;
  esac
done

command -v kubectl >/dev/null || die "kubectl is not installed"
[[ -d "$DEPLOY_DIR" ]] || die "no manifest/ directory next to this script"

case "$ENGINE" in
  kustomize) ;;
  helm)
    command -v helm >/dev/null || die "helm is not installed"
    [[ -f "${HELM_DIR}/Chart.yaml" ]] || die "no chart at ${HELM_DIR#"${HERE}"/}"
    ;;
  *) die "--engine must be 'kustomize' or 'helm', not '$ENGINE'" ;;
esac

# single-cloud addresses nothing by name. Its two exposed addresses — the
# gateway's and PRAN's — are read back from their Services and substituted into
# the out-of-cluster configs, so there is nothing to inject as hostAliases.
# multi-cloud still names the controller and the three gateways.
case "$DEPLOYMENT" in
  single) HOSTS_FILE="" ;;
  multi)  HOSTS_FILE="${DEPLOY_DIR}/multi-cloud/dns-hosts" ;;
  *) die "--deployment must be 'single' or 'multi', not '$DEPLOYMENT'" ;;
esac

# The manifests name the controller and the gateways instead of addressing
# them; dns-hosts is where those names get their addresses. Emitted as
# `hostAliases` on exactly the pods that dial across a cluster boundary — the
# controller probes every gateway's advertised address, and a gateway dials the
# controller and, for the proxy path, its peers. NF pods reach their own
# gateway through cluster DNS and need none of this.
#
# One address per line, then the names on it; comments and blanks ignored.
read_hosts() {
  [[ -f "$HOSTS_FILE" ]] || return 0
  sed 's/#.*//' "$HOSTS_FILE" \
    | awk 'NF >= 2 { for (i = 2; i <= NF; i++) print $1, $i }' \
    | awk '{ names[$1] = names[$1] " " $2; if (!($1 in seen)) { seen[$1] = ++n; order[n] = $1 } }
           END { for (i = 1; i <= n; i++) print order[i] names[order[i]] }'
}

HOSTS_N=$(read_hosts | wc -l)

# The same addresses as a JSON array, which is how the chart takes them.
hosts_json() {
  local ip names n first=1 f2
  printf '['
  while read -r ip names; do
    (( first )) || printf ','
    first=0
    printf '{"ip":"%s","hostnames":[' "$ip"
    f2=1
    for n in $names; do (( f2 )) || printf ','; f2=0; printf '"%s"' "$n"; done
    printf ']}'
  done < <(read_hosts)
  printf ']'
}

# The chart arguments for one cloud: its values file if it has one, the
# registry and tag unless -l, and the names from dns-hosts. Everything the
# overlay does for kustomize, the chart takes as values.
helm_args() {
  local cloud="$1"
  # --create-namespace, because a chart cannot own the namespace it installs
  # into: Helm writes the release record there before creating any resource.
  # It is left behind by `helm uninstall`, unlike everything in it.
  local -a a=( --namespace "$NAMESPACE" --create-namespace )
  # one values file per cloud of a multi-cloud deployment; single-cloud is the
  # chart's defaults and has none. A cloud named here with no values file is a
  # cloud the chart does not describe, so refuse rather than install its
  # defaults under that cloud's name.
  if [[ "$DEPLOYMENT" == "multi" ]]; then
    [[ -f "${HELM_DIR}/values/${cloud}.yaml" ]] \
      || die "no chart values for cloud '${cloud}' (${HELM_DIR#"${HERE}"/}/values/${cloud}.yaml)"
    a+=( -f "${HELM_DIR}/values/${cloud}.yaml" )
  fi
  (( LOCAL )) || a+=( --set "image.prefix=${IMAGE}" --set "image.tag=${TAG}" )
  (( HOSTS_N > 0 && ! NO_HOSTS )) && a+=( --set-json "hostAliases=$(hosts_json)" )
  printf '%s\n' "${a[@]}"
}

if (( PRINT_HOSTS )); then
  [[ -n "$HOSTS_FILE" ]] \
    || die "--print-hosts is for --deployment multi; single-cloud names nothing"
  if (( HOSTS_N == 0 )); then
    die "no entries in ${HOSTS_FILE#"${HERE}"/} — fill it in first"
  fi
  echo "# volantis ${DEPLOYMENT}-cloud — from ${HOSTS_FILE#"${HERE}"/}"
  read_hosts | awk '{ printf "%-16s", $1; for (i = 2; i <= NF; i++) printf " %s", $i; print "" }'
  exit 0
fi

if (( ! LOCAL )); then
  [[ -n "$TAG" ]] || die "empty tag"
  [[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "not a valid image tag: $TAG"
fi

# ---- which clouds, and which directory each one is ------------------------
declare -a clouds=()
declare -A cloud_dir=() cloud_ctx=()

add_cloud() {
  local spec="$1" name ctx dir
  name="${spec%%=*}"
  ctx="$CONTEXT"
  [[ "$spec" == *=* ]] && ctx="${spec#*=}"

  case "$DEPLOYMENT" in
    single) [[ "$name" == "single" ]] || die "--cloud is for --deployment multi"
            dir="${DEPLOY_DIR}/single-cloud" ;;
    multi)  case "$name" in
              central|edge1|edge2) dir="${DEPLOY_DIR}/multi-cloud/${name}" ;;
              *) die "unknown cloud '$name' (central, edge1, edge2)" ;;
            esac ;;
  esac
  [[ "$ENGINE" == "helm" ]] || [[ -f "${dir}/kustomization.yaml" ]] \
    || die "no kustomization.yaml in ${dir}"

  clouds+=( "$name" )
  cloud_dir["$name"]="$dir"
  cloud_ctx["$name"]="$ctx"
}

if [[ "$DEPLOYMENT" == "single" ]]; then
  [[ -z "$CLOUD_ARG" ]] || die "--cloud is for --deployment multi"
  add_cloud "single"
else
  [[ -n "$CLOUD_ARG" ]] || CLOUD_ARG="central,edge1,edge2"
  for spec in ${CLOUD_ARG//,/ }; do add_cloud "$spec"; done
fi

confirm() {
  (( ASSUME_YES )) && return 0
  local prompt="$1" reply=""
  # Prompt on the terminal, not on stdin, so a piped stdin cannot answer for
  # the operator. With no terminal at all there is nobody to ask: say so
  # instead of dying on an unset variable.
  if ! read -r -p "$prompt [y/N] " reply </dev/tty 2>/dev/null; then
    echo "no terminal to prompt on — pass -y to proceed unattended" >&2
    return 1
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

# kubectl with the cloud's context, if it has one.
kc() {
  local cloud="$1"; shift
  if [[ -n "${cloud_ctx[$cloud]}" ]]; then
    kubectl --context "${cloud_ctx[$cloud]}" "$@"
  else
    kubectl "$@"
  fi
}

# helm, likewise.
hc() {
  local cloud="$1"; shift
  if [[ -n "${cloud_ctx[$cloud]}" ]]; then
    helm --kube-context "${cloud_ctx[$cloud]}" "$@"
  else
    helm "$@"
  fi
}

# ---- the overlay ----------------------------------------------------------
# Derived from the manifests rather than from a hard-coded list, so a new NF
# Deployment is picked up by adding it to the base kustomization and nothing
# else. Only volantis-* images are listed: mongo:7 is left alone.
images_in() {
  grep -hE '^ *-? *image: ' "$1"/*.yaml \
    | sed 's/.*image: //; s/:.*//' \
    | grep "^${LOCAL_NAME}-" | sort -u
}

# One strategic-merge patch per deployment that needs the names. hostAliases
# merges on `ip`, so the addresses are grouped rather than repeated.
write_alias_patch() {
  local ovl="$1" dep="$2" ip
  {
    echo "# Generated by k8s-deploy.sh from ${HOSTS_FILE#"${HERE}"/}."
    echo "apiVersion: apps/v1"
    echo "kind: Deployment"
    echo "metadata:"
    echo "  name: ${dep}"
    echo "  namespace: ${NAMESPACE}"
    echo "spec:"
    echo "  template:"
    echo "    spec:"
    echo "      hostAliases:"
    while read -r ip names; do
      echo "        - ip: \"${ip}\""
      echo "          hostnames:"
      for n in $names; do echo "            - \"${n}\""; done
    done < <(read_hosts)
  } > "${ovl}/hostaliases-${dep}.yaml"
}

# kustomize rejects absolute paths in `resources:`, so the overlay has to live
# at a fixed relative distance from the base. manifest/.deploy/<cloud> is it.
write_overlay() {
  local cloud="$1" dir="${cloud_dir[$1]}" ovl="${OVERLAY_ROOT}/$1" img dep
  local -a patched=()
  rm -rf "$ovl"; mkdir -p "$ovl"

  if (( HOSTS_N > 0 && ! NO_HOSTS )); then
    for dep in ctrl-dep gateway-dep; do
      # only the deployments this cloud actually has: kustomize errors on a
      # patch that matches nothing
      grep -qs "name: ${dep}\$" "$dir"/*.yaml || continue
      write_alias_patch "$ovl" "$dep"
      patched+=( "$dep" )
    done
  fi

  {
    echo "# Generated by k8s-deploy.sh. Edits are lost on the next run."
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo
    echo "resources:"
    echo "  - $(realpath --relative-to="$ovl" "$dir")"
    if (( ! LOCAL )); then
      echo
      echo "images:"
      while read -r img; do
        [[ -n "$img" ]] || continue
        # volantis-amf -> <IMAGE>-amf, so the local name's suffix carries over
        echo "  - name: ${img}"
        echo "    newName: ${IMAGE}${img#"$LOCAL_NAME"}"
        echo "    newTag: ${TAG}"
      done < <(images_in "$dir")
    fi
    if (( ${#patched[@]} )); then
      echo
      echo "patches:"
      for dep in "${patched[@]}"; do
        echo "  - path: hostaliases-${dep}.yaml"
      done
    fi
  } > "${ovl}/kustomization.yaml"
  echo "$ovl"
}

# ---- report ---------------------------------------------------------------
verb="apply"; (( DELETE )) && verb="DELETE"
echo "Deployment: ${DEPLOYMENT}"
if [[ "$ENGINE" == "helm" ]]; then
  echo "Engine:     helm — release ${RELEASE} from ${HELM_DIR#"${HERE}"/}"
else
  echo "Engine:     kustomize"
fi
echo "Clouds:     ${clouds[*]}"
if (( LOCAL )); then
  echo "Images:     as written — ${LOCAL_NAME}-<nf>:latest, from the local runtime"
else
  echo "Images:     ${IMAGE}-<nf>:${TAG}"
fi
echo "Action:     ${verb} into namespace ${NAMESPACE}"
if [[ -z "$HOSTS_FILE" ]]; then
  :   # nothing is addressed by name in this deployment
elif (( NO_HOSTS )); then
  echo "Names:      --no-hosts; ctrl/gw names must resolve through real DNS"
elif (( HOSTS_N > 0 )); then
  echo "Names:      ${HOSTS_N} address(es) from ${HOSTS_FILE#"${HERE}"/}, as hostAliases"
else
  echo "Names:      ${HOSTS_FILE#"${HERE}"/} has no entries — ctrl/gw names will not"
  echo "            resolve from a pod unless real DNS serves them"
fi

for c in "${clouds[@]}"; do
  printf '  %-8s %-28s context=%s\n' "$c" \
    "${cloud_dir[$c]#"${HERE}"/}" "${cloud_ctx[$c]:-<current>}"
done

# ---- render ---------------------------------------------------------------
# Both engines render before anything is applied, so a broken manifest or a
# value the chart refuses is reported here rather than half way through a
# cluster.
declare -A target=()
declare -A hargs=()
if [[ "$ENGINE" == "kustomize" ]]; then
  for c in "${clouds[@]}"; do
    if (( LOCAL )) && (( HOSTS_N == 0 || NO_HOSTS )); then
      target["$c"]="${cloud_dir[$c]}"   # nothing to rewrite; apply the base itself
    else
      target["$c"]="$(write_overlay "$c")"
    fi
    kubectl kustomize "${target[$c]}" >/dev/null || die "$c: kustomize render failed"
  done
else
  for c in "${clouds[@]}"; do
    # one line per argument, so a value containing a space would still survive
    mapfile -t a < <(helm_args "$c")
    hargs["$c"]="$(printf '%s\n' "${a[@]}")"
    helm template "$RELEASE" "$HELM_DIR" "${a[@]}" >/dev/null \
      || die "$c: chart render failed"
  done
fi

# The arguments this cloud's helm invocations take, back as an array in $a.
helm_argv() { mapfile -t a <<<"${hargs[$1]}"; }

if (( DRY_RUN )); then
  for c in "${clouds[@]}"; do
    echo
    echo "==> ${c}: images after rendering"
    if [[ "$ENGINE" == "kustomize" ]]; then
      kubectl kustomize "${target[$c]}" | grep -E '^ *-? *image: ' \
        | sed 's/^ *-\? *//; s/^/    /' | sort -u
    else
      helm_argv "$c"
      helm template "$RELEASE" "$HELM_DIR" "${a[@]}" | grep -E '^ *-? *image: ' \
        | sed 's/^ *-\? *//; s/^/    /' | sort -u
    fi
    echo "==> ${c}: diff against the cluster"
    if (( DELETE )); then
      echo "    (skipped — nothing to diff for a delete)"
    elif [[ "$ENGINE" == "helm" ]]; then
      # `helm diff` is a plugin and is not assumed to be installed. Without it
      # there is nothing honest to print here, so say that rather than imply
      # the rendering above was compared with anything.
      echo "    (skipped — install the helm-diff plugin for a diff against the release)"
    else
      # kubectl diff exits 1 when there are differences, which is the point.
      # It exits 1 for a missing namespace too, which is just a first deploy.
      out="$(kc "$c" diff -k "${target[$c]}" 2>&1 || true)"
      if [[ "$out" == *"namespaces \"${NAMESPACE}\" not found"* ]]; then
        echo "    namespace ${NAMESPACE} does not exist yet — every resource here is new"
      else
        sed 's/^/    /' <<<"$out"
      fi
    fi
  done
  echo
  echo "[dry-run] nothing applied"
  exit 0
fi

confirm "${verb} ${#clouds[@]} cloud(s)?" || { echo "aborted"; exit 1; }

# ---- apply / delete -------------------------------------------------------
failed=()
for c in "${clouds[@]}"; do
  echo "==> ${c}"
  if [[ "$ENGINE" == "helm" ]]; then
    helm_argv "$c"
    if (( DELETE )); then
      # helm 3.12 has no --ignore-not-found, so ask first. The Namespace is a
      # chart resource, so this takes the whole deployment with it, the UDR's
      # volume included.
      if hc "$c" status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
        hc "$c" uninstall "$RELEASE" --namespace "$NAMESPACE" || failed+=( "$c" )
      else
        echo "    no ${RELEASE} release in ${NAMESPACE} — nothing to uninstall"
      fi
    else
      # No --wait: readiness is leadership on the controller, so at two
      # replicas exactly one pod is ever Ready and --wait would sit there until
      # it timed out. -w below is the check that knows that.
      hc "$c" upgrade --install "$RELEASE" "$HELM_DIR" "${a[@]}" \
        || failed+=( "$c" )
    fi
  elif (( DELETE )); then
    kc "$c" delete -k "${target[$c]}" --ignore-not-found || failed+=( "$c" )
  else
    kc "$c" apply -k "${target[$c]}" || failed+=( "$c" )
  fi
done

if (( ${#failed[@]} )); then
  printf '%s failed for %d cloud(s): %s\n' "$verb" "${#failed[@]}" "${failed[*]}" >&2
  exit 1
fi

if (( DELETE )); then
  echo "deleted ${#clouds[@]} cloud(s)"
  exit 0
fi

# ---- wait -----------------------------------------------------------------
# Two different checks, because the controller's readiness is deliberately not
# what a Deployment calls Available. Readiness IS leadership there: with
# replicas: 2 exactly one pod is ever Ready, so neither `condition=Available`
# nor `rollout status` — both of which want every replica available — ever
# arrives. What "the controller is up" means there is: every pod is on the new
# template, no old pod is left, and one of them holds the lease.
#
# For everything else it is `rollout status`, and not `condition=Available`:
# during an upgrade a Deployment stays Available on its *old* replicas, so
# Available is satisfied the moment the command is issued and says nothing about
# whether the new ones came up.
if (( WAIT )); then
  for c in "${clouds[@]}"; do
    echo "==> ${c}: waiting (${WAIT_TIMEOUT})"
    deps="$(kc "$c" -n "$NAMESPACE" get deploy -o name | sed 's|deployment.apps/||')"
    for d in $deps; do
      if [[ "$d" == "ctrl-dep" ]]; then
        want="$(kc "$c" -n "$NAMESPACE" get "deploy/$d" -o jsonpath='{.spec.replicas}')"
        if kc "$c" -n "$NAMESPACE" wait --for=jsonpath='{.status.updatedReplicas}'="$want" \
             "deploy/$d" --timeout="$WAIT_TIMEOUT" \
           && kc "$c" -n "$NAMESPACE" wait --for=jsonpath='{.status.replicas}'="$want" \
             "deploy/$d" --timeout="$WAIT_TIMEOUT" \
           && kc "$c" -n "$NAMESPACE" wait --for=jsonpath='{.status.readyReplicas}'=1 \
             "deploy/$d" --timeout="$WAIT_TIMEOUT"; then
          echo "deployment.apps/$d rolled out, one replica holding the lease"
        else
          failed+=( "${c}/${d}" )
        fi
      else
        kc "$c" -n "$NAMESPACE" rollout status "deploy/$d" \
          --timeout="$WAIT_TIMEOUT" || failed+=( "${c}/${d}" )
      fi
    done
  done
  if (( ${#failed[@]} )); then
    printf '\nnot up within %s:\n' "$WAIT_TIMEOUT" >&2
    printf '  %s\n' "${failed[@]}" >&2
    echo "A pod that is Running but not Ready has not finished its NSM pull." >&2
    exit 1
  fi
fi

echo "${verb%%[[:space:]]*} done: ${#clouds[@]} cloud(s)"
