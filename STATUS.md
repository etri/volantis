# Status

What's in this repo today, and what isn't.

<!-- TODO: set the release tag, e.g. v0.1.0 -->
**Release:** `TODO`

## Source code

**Volantis will be open source.** We're waiting on approval from the institution that
manages the project, and we'll update this repo when it comes through.

Part of it is already released. The protocol layer is developed as standalone Go
libraries you can use today, with or without Volantis:
[`sbi`](https://github.com/reogac/sbi), [`nas`](https://github.com/reogac/nas),
[`ngap`](https://github.com/lvdund/ngap), [`pfcp`](https://github.com/reogac/pfcp).

What's pending is the network functions and the service mesh.

## Components

| Component | Image | Manifest | Source |
|---|:--:|:--:|:--:|
| Mesh Controller | ⏳ | ✅ | ⏳ |
| Gateway | ⏳ | ✅ | ⏳ |
| Mesh Agent | in NF images | — | ⏳ |
| Proxy-RAN | ⏳ | ✅ | ⏳ |
| DAMF | ⏳ | ✅ | ⏳ |
| AMF | ⏳ | ✅ | ⏳ |
| SMF | ⏳ | ✅ | ⏳ |
| UPF | ⏳ | host config | ⏳ |
| AUSF | ⏳ | ✅ | ⏳ |
| UDM | ⏳ | ✅ | ⏳ |
| PCF | ⏳ | ✅ | ⏳ |
| NSM (extended NSSF) | ⏳ | ✅ | ⏳ |

✅ available · ⏳ pending

**The images are published**, at `ghcr.io/reogac/volantis-<nf>:v0.1.1` — one per network
function, plus the UPF. The packages are public, so pulling needs no registry account.
No manifest names a registry: [`k8s-deploy.sh`](deploy/k8s/k8s-deploy.sh) supplies the
prefix and the tag, to a kustomize overlay or to the chart, and `IMAGE` at the top of it
is the only place that prefix is written. Point it elsewhere to pull from a mirror.

**Binaries aren't published yet either.** [`bin/`](bin/) is where they go, and
[`deploy-local.sh`](deploy/deploy-local.sh) runs the whole core from there on one machine — see
[bin/README.md](bin/README.md) and [deploy/local/](deploy/local/README.md).

The **mesh agent** is a library linked into each network function, not a sidecar, so it
has no image of its own.

**There is no autoscaler here.** Scaling is `kubectl scale`, and the mesh's contribution is
the occupancy signal every instance publishes on `/state` — it never talks to an actuator.
[`single-cloud/README.md` §5.6](deploy/k8s/manifest/single-cloud/README.md#56-autoscaling) has an
example HPA driven by that signal; it is deliberately not applied by the manifests, because
it needs a metrics pipeline they do not install and a target measured on your hardware rather
than guessed.

The **UPF** isn't a cluster workload. Its data path needs the `gtp5g` kernel module on
the host, so it runs as a process beside the cluster — and neither is UERANSIM, which is the
radio. Both live in [`deploy/external/`](deploy/external/README.md), one copy shared by every
deployment: it carries the config templates, the scripts that run them, and an end-to-end
test, and it is told each deployment's addresses as arguments rather than edited per
deployment.

**Two deployments are new in this release**, both under `deploy/k8s/manifest/`:
[`single-cloud/`](deploy/k8s/manifest/single-cloud/README.md)
(one cluster, one gateway, only the UPF outside it) and
[`multi-cloud/`](deploy/k8s/manifest/multi-cloud/README.md) (three clusters, one mesh — a central
cloud and two edges, with locality routing and the controller in HA). They replace the
earlier flat `deploy/manifest/` set, which described an older deployment model — a different
namespace, Multus with static addresses instead of `LoadBalancer` Services, and an autoscaler
CRD that does not exist.

**[`deploy/k8s/helm/`](deploy/k8s/helm/) has been rebuilt** against `single-cloud/` and now
installs it as a Helm release — verified on minikube on 2026-08-28: 14 pods ready, the
mesh converged with every service definition read from the namespace's Service objects,
and no `level=error` past the first twenty seconds of start-up retries. Re-verified the
same day against the **published `v0.1.1` images**, pulled from ghcr by an unauthenticated
node: all fourteen pods on the released build, the mesh converged to seventeen definitions
and eleven endpoints, and the only errors the few seconds of the controller's own
handover. The same chart
covers multi-cloud through `values/{central,edge1,edge2}.yaml`, one release per cluster;
like the manifests it describes, that half is rendered and checked but not run. It is a second hand-written copy of both deployments, so
[`deploy/k8s/check-parity.sh`](deploy/k8s/check-parity.sh) renders both and diffs them —
semantically, with each ConfigMap's embedded NF configuration decoded first — and that is
what stops the two from drifting the way the old chart did. `./deploy/k8s/k8s-deploy.sh
--engine helm` drives it.

**The single-machine deployment is verified end to end**, with UERANSIM driving real
signalling: NG Setup, 5G-AKA over SUCI, the DAMF-to-AMF handover, a PDU session on
`10.60.0.1`, and traffic over the tunnel in both directions. Three commands bring it up —
see [deploy/local/README.md](deploy/local/README.md), which states every requirement and
checks them before it starts anything.

**The single-cloud Kubernetes deployment is verified end to end too** (2026-08-27, on
minikube): all 13 pods ready, Proxy-RAN running *in* the cluster behind an SCTP
`LoadBalancer`, NG Setup from a UERANSIM gNB, subscribers provisioned through `uegen`, a UE
completing 5G-AKA over SUCI and the DAMF-to-AMF handover, then a PDU session on `10.60.0.1`
with both SMFs associating to the UPF and ICMP and DNS crossing the tunnel — `upfgtp`
counting in both directions, and nothing at `level=error` in the UPF's log.

The UPF and UERANSIM ran outside the cluster from
[`deploy/external/`](deploy/external/README.md), told the deployment's two published
addresses and a port-forward to the database, which is the whole of what that artifact
needs to know about a deployment.

**The multi-cloud deployment is not verified**: it needs three machines, and the manifests
and this guide are written from the single-cloud one rather than from a run.

## Repo content

| | |
|---|---|
| Single-cloud manifests and guide | ✅ in `deploy/k8s/manifest/single-cloud/` |
| Multi-cloud manifests and guide | ✅ in `deploy/k8s/manifest/multi-cloud/` |
| Single-machine deployment | ✅ in `deploy/local/` |
| Service definitions | ✅ in each deployment's `service-definitions.yaml` |
| Subscriber provisioning (`uegen`) | ✅ in `deploy/external/` |
| UERANSIM, `gtp5g` and `gtp5g-tunnel` | not shipped — other people's projects, built from source; [bin/README.md](bin/README.md) says how |
| UPF, gNB and UE, outside a cluster | ✅ in `deploy/external/`, with an end-to-end test |
| Quickstart | ✅ |
| Published images | ✅ `ghcr.io/reogac/volantis-<nf>:v0.1.1` |
| The binary bundle | ✅ [`volantis-v0.1.1.tar.gz`](https://github.com/etri/volantis/releases/download/v0.1.1/volantis-v0.1.1.tar.gz) — unpack at the repository root; [bin/README.md](bin/README.md) says how |
| Helm chart | ✅ both deployments, in `deploy/k8s/helm/` |
| TLS / mTLS, SEPP and roaming, gateway HA | not in this repo |
| Source code | ⏳ |

## Dependencies

| What | Used for | License |
|---|---|---|
| [`gtp5g`](https://github.com/free5gc/gtp5g) `0.8.1 <= v < 0.9.20` | UPF kernel data path. The UPF checks the loaded version at startup and refuses anything outside that range; 0.8.2 and 0.8.3 are the tested ones | GPL-2.0 |
| MongoDB | Subscriber data (replaces the UDR) | SSPL |
| [StormSIM](https://github.com/lvdund/StormSIM) | UE/gNodeB emulator | Apache-2.0 |
| [UERANSIM](https://github.com/aligungr/UERANSIM) | UE/gNodeB emulator | GPL-3.0 |

## Licensing

Everything in this repo is Apache 2.0 — see [LICENSE](LICENSE).

Container images and prebuilt binaries are for research and evaluation use until the
source is released.
<!-- TODO: confirm the binary terms with the institution, or add LICENSE-BINARIES.md. -->
