# Volantis chart

Install either deployment as a Helm release. The chart's **defaults are the
single-cloud deployment** — one cluster, one gateway, only the UPF outside it —
and the three files in [`values/`](values/) are the **multi-cloud** one, a
central cloud and two edges.

Each renders the same resources as the matching directory under
[`../manifest/`](../manifest/). What the deployments *do*, and how to drive one
end to end, is in those READMEs
([single-cloud](../manifest/single-cloud/README.md),
[multi-cloud](../manifest/multi-cloud/README.md)); this covers only what is
different about installing them as releases.

## Install

You need Helm 3, `kubectl`, a cluster, and a `LoadBalancer` provider. Run from
the repository root.

```bash
helm install volantis deploy/k8s/helm --namespace volantis --create-namespace

# or through the script, which pins the image tag for one run
./deploy/k8s/k8s-deploy.sh --engine helm -t v0.2.0
```

The chart names `ghcr.io/reogac/volantis-<nf>:v0.1.1` out of the box. The
packages are public, so pulling needs no registry account.

Check what came up:

```bash
kubectl -n volantis get pods
```

> Note: **`--create-namespace` is not optional**, and exactly one controller pod
> is ever `Ready`. Both are explained in [§ What will catch you](#what-will-catch-you).

For three clusters, install one release per cluster, each with its own values
file and kube context. Order does not matter — every component retries its way
into the mesh — but central holds the controller, so nothing converges until it
is up.

```bash
./deploy/k8s/k8s-deploy.sh --engine helm -d multi -t v0.1.1 \
  -c central=<ctx>,edge1=<ctx>,edge2=<ctx>
```

Use the script rather than plain `helm` here: it turns
[`../manifest/multi-cloud/dns-hosts`](../manifest/multi-cloud/dns-hosts) into the
`hostAliases` value for exactly the two pods that dial across a cluster boundary,
which is the only reason the controller and the gateways can be addressed by
name. By hand that is:

```bash
helm install volantis deploy/k8s/helm -n volantis --create-namespace \
  -f deploy/k8s/helm/values/edge1.yaml --kube-context <ctx> \
  --set-json 'hostAliases=[{"ip":"203.0.113.10","hostnames":["ctrl.volantis.lab"]}]'
```

## What each values file changes

| | central | edge1 / edge2 |
| --- | --- | --- |
| controller | 2 replicas, `ha: true` | absent |
| NSM, UDR, UDM, AUSF, PCF | present | absent — reached across the mesh |
| service definitions | declared here, and only here | absent |
| gateway `advertise` | `local` and `external` | `external` only |
| gateway `controller` | the ClusterIP name | `ctrl.volantis.lab`, by name |
| `meshLabels.cloud` | `central` | `edge1` / `edge2` |
| PRAN `tac` | `001` | `002` / `003` |
| locality routing | enabled, three clouds | not rendered here |

**All three clusters must agree on `routing.clouds`.** The definitions are
written once, in the cluster that runs the controller.

## Common overrides

```bash
# a mirror, or a version other than the chart's default
--set image.prefix=my-registry.example.com/volantis --set image.tag=v0.2.0

# scale a set or a slice
--set amf.sets[0].replicas=4

# real SUCI keys — the ones in values.yaml are published test keys
-f my-suci.yaml
```

To add an AMF set, add one entry to `amf.sets` and one to `nsm.config.amfSets`;
its service definition is derived. Same for a slice, in `smf.slices` and
`nsm.config.slices`.

## Keep the two copies in step

The manifests and this chart are both hand-written, and two copies of one thing
drift. Run this after editing either side:

```bash
./deploy/k8s/check-parity.sh            # single-cloud
./deploy/k8s/check-parity.sh -d multi   # central, edge1 and edge2
./deploy/k8s/check-parity.sh -d all     # every cloud of both
```

It renders both, decodes the NF configuration embedded in each ConfigMap so key
order does not count as a difference, and diffs the results. A change made to one
side and not the other is drift, and this is the only thing that will say so.

## What the chart refuses

Several ways of misconfiguring this deployment are accepted by Kubernetes and
show up much later as a network function that registers and is never selectable.
The chart fails the render instead:

| refused | because |
| --- | --- |
| empty `nsm.suciProfiles` | a UDM with no profile fails authentication for every UE and never becomes ready |
| a quoted `protectionScheme` | NSM types it `int16` and the process exits at startup |
| a gateway advertising neither `local` nor `external` | startup error |
| an unset `gateway.id` | agents cache it as the `GwId` of every endpoint behind this gateway |
| a `gateway.id` absent from `controller.gateways` | the controller refuses a gateway that is not on the allow-list |
| an `amf.sets` entry with no `nsm.config.amfSets` entry | that set would serve no slice |
| an `smf.slices` entry NSM does not declare | that slice would have no producer |
| a `pran.amfRegion` matching no AMF set | PRAN refuses to open its SCTP listener |
| a `pran.transportNetworks` entry NSM does not declare | the SMF's path search finds no source face, and session establishment fails for every UE on that PRAN |
| an unquoted `mcc`, `mnc`, `tac`, `sd` or AMF set id | YAML reads `001` as the number 1, and the label comes out quietly wrong |
| a **quoted** `smf.slices` `sst` | it is a number in the NF's configuration, not a string |

Keep the quoting from `values.yaml` when you override.

## What is a value and what is not

Everything a deployment varies is a value, and `values.yaml` documents each one
where it is defined. Two things are deliberately **not** knobs:

- **Resource names.** `ctrl-svc`, `gateway-svc`, `pran-svc`, `udr-mongo`,
  `amf-10-100-dep` and the rest are literal, with no release prefix. The
  out-of-cluster scripts in [`../../external/`](../../external/) and both
  deployment READMEs tell you to read the `pran-svc` and `gateway-svc`
  EXTERNAL-IPs and to port-forward `udr-mongo`; a release-prefixed name would
  break every one of those instructions. Install one release per cluster.
- **The gateway's replica count.** Gateway HA is not implemented, and the process
  holds per-domain registration state that nothing replicates.

Not in the chart at all: an autoscaler — scale with `kubectl scale` or a replica
count, driven by the occupancy signal on each NF's `/state` — no SEPP, and no OAM
client. The UDR stays ClusterIP.

---

## What will catch you

**`--create-namespace` is not optional.** Helm writes the release's own record
into the target namespace before it creates any resource, so a chart cannot own
the namespace it installs into. Without the flag the install fails with
`namespaces "volantis" not found`; declaring the Namespace in the chart *as well*
fails the other way with `already exists`. `namespace.create` is therefore false
by default and exists for the render-and-apply path, where there is no release
record and the Namespace is an ordinary resource:

```bash
helm template volantis deploy/k8s/helm --set namespace.create=true | kubectl apply -f -
```

That is also the rendering `check-parity.sh` compares, so the manifests'
`namespace.yaml` is not counted as a missing resource.

**Do not use `--wait`.** Readiness is leadership on the controller: a replica
that does not hold the Lease answers 503 on purpose, so at two replicas exactly
one pod is ever Ready and `--wait` sits there until it times out. `k8s-deploy.sh
-w` checks for one ready replica instead, and works with either engine.

**An upgrade restarts the controller with a short gap, on purpose.** Its
Deployment takes the old replica down before starting the new one, because a
replica that does not hold the Lease is not Ready and a surging rollout would
deadlock. During the handover the gateway logs a failed re-registration and the
new controller logs an endpoint uuid it does not know; the gateways then replay
into it and both stop. Nothing else is interrupted — agents resolve client-side
from what they have cached.

**`helm uninstall` leaves the namespace behind**, because Helm created it rather
than the chart — but it does delete the UDR's PersistentVolumeClaim, and with it
whatever subscribers `uegen` last provisioned. Re-provisioning them is one
command; `kubectl delete ns volantis` removes the rest.

**Deleting the namespace by hand orphans the release.** Helm keeps its release
record in a Secret in that namespace, so the next `helm upgrade` fails until you
`helm uninstall` it.

**Locality routing reads two labels, set in two different places**, and getting
either wrong fails silently — the service works, but not locally.
`gateway.labels.<key>` is the producer side, stamped by the gateway onto every
endpoint it registers; `meshLabels.<key>` is the consumer side, the agent's own
view of itself. One `routing.key` names both, and the chart renders `_gw-<key>`
for the first. Turn it on with `routing.enabled` plus `routing.clouds`, and it
lands on the definitions where selection actually happens: the DAMF, each AMF set
and each SMF slice.
