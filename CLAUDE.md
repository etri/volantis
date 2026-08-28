# CLAUDE.md — the public artifacts repo

Guidance for Claude Code working inside `repo/`. The root `../CLAUDE.md`
describes the **source tree** and still applies; this file is only what is
different here, and only the rules.

**Why any rule is what it is** — the decision, its date, the run that verified it
or the failure that produced it — is in `.claude/decisions.md`, which is
maintainer notes and is not part of a clone. Read it before reopening a rule,
not before an ordinary edit.

## What this is

`repo/` is a separate git repository (`git@github.com:reogac/volantis.git`,
public target `github.com/etri/volantis`) checked out inside the source tree. It
holds what a reader needs to *run* Volantis — manifests, a Helm chart, configs,
two runners — not the source. `src/` is a placeholder; `STATUS.md` is the
inventory.

**Never commit here without being asked.** This is the repository that goes
public.

## Standing rules — do not reopen

- **Out of scope. Do not add back:** SEPP · `oam-cli` · an autoscaler or its CRD
  · a routable UDR (MongoDB stays ClusterIP; `uegen` reaches it by
  `kubectl port-forward`) · the local-image `-l` path of `k8s-deploy.sh` ·
  multi-UPF chains and ULCL · mTLS certificates in the manifests · documenting
  definition `groups`/`routes`.
- **Gateway HA is design-only** — every `gateway.yaml` stays `replicas: 1`.
  Controller HA is implemented and ported: leases RBAC and Services write verbs
  at **any** replica count, `maxUnavailable: 1, maxSurge: 0`, readiness is
  leadership.
- **Nothing here may cite the parent tree.** `../docs/`, `../.claude/`,
  `../TODOs.md`, `../nfs/`, `../mesh/`, `../util/` do not ship, so a pointer to
  one is a dead reference in released material — manifests, configs and prose
  alike. Say the reason inline. Spec citations (`TS 29.281`) are fine.
- **`deploy/k8s/manifest/` and `deploy/external/` are each the only copy.**
  Editing them changes the lab's deployment. Do not fork a second copy of either.
- **Edit the chart and the manifests together**, then run
  `deploy/k8s/check-parity.sh`. Leaving it failing is drift, not a finished
  change.
- **`helm --wait` must not be used** — readiness is leadership, so exactly one
  controller pod is ever Ready. `k8s-deploy.sh -w` does the wait that knows this.
- **Chart shapes that are settled:** resource names are literal, with no release
  prefix; the chart cannot own its namespace (`--create-namespace`,
  `namespace.create: false`); locality routing is derived from `routing.clouds` +
  `routing.key`, never hand-copied per cloud.
- **The default `TAG` must be a tag that exists** in ghcr, and it is written in
  nine places — the constant, its usage line, `Chart.yaml`'s `appVersion`, six
  lines of prose.
- **one end to end test for all deployments**. There is a single guide to deploy UPF, gnB and UE to make end-to-end test to the control plane deplyed in a local machine, a single cloud, or multi-cloud.

## House style

Every README, chart values file and config comment. Where a style rule names a
stack this repo does not have — Docker/Podman, Istio, NWDAF, Anycast — keep the
rule and drop the technology.

- **Write for a reader in a hurry.** The audience wants the system *deployed*,
  not explained. Lead with the commands: a quick start, then one short section
  per thing to run. **Explanation goes last**, in a section a reader can skip
  whole. Prefer a table or a command block to a paragraph. Cut a sentence rather
  than keep one that is merely true.
- **Second person, active imperatives.** "you"; Clone, Apply, Label, Expose.
  Never "the YAML file should be configured".
- **One action or concept per sentence.**
- **Define a component immediately before its first configuration block**, in a
  line — never in a concepts chapter up front.
- **Outcome first:** an architecture diagram placeholder and the verification
  test that proves the end state, before any step.
- **A prerequisites block with exact versions** — kernel, `gtp5g`'s range,
  kubectl / helm / minikube, UERANSIM, what must be reachable from where.
- **Strict chronological numbering** for tasks.
- **Conceptual asides stay out of the command flow** — a `> Note:` callout, or
  the last section.
- **Every code block is complete and copy-pasteable.** No `...` inside one; a
  value the reader supplies is a named placeholder (`<pran-svc IP>`).

## Layout

```
.gitignore       tracked, so its rules reach a clone
bin/             where binaries go; ships only README.md
deploy/
  deploy-local.sh     the single-machine deployment — start/stop/status/logs
  local/              its control plane only: one loopback address per component
  deploy-external.sh  the components outside a cluster, against any deployment
  external/           the UPF, a UERANSIM gNB, the UEs, uegen — one copy, told
                      each deployment's addresses as arguments; `e2e` is the test
  run/                both runners' working directory. Gitignored
  k8s/
    k8s-deploy.sh     applies a deployment, pinned to one image tag. IMAGE and
                      TAG are constants at its top — the only image prefix here
    manifest/single-cloud/   one cluster, only the UPF outside it
    manifest/multi-cloud/    a central cloud and two edges, one mesh
    helm/                    both deployments as one chart; values/*.yaml are
                             the multi-cloud clusters
    check-parity.sh          renders both and diffs them
src/             placeholder — see STATUS.md
```
## Open questions — ask, do not assume

1. Publish the chart to ghcr as an OCI artifact? Deferred — it would be a third
   place holding the registry destination.
2. Has institutional approval for the source release come through? Until it has,
   `src/` stays a placeholder.
3. Traffic routing and mTLS certificates in the manifests: out of scope until
   asked.
