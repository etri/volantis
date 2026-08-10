# Manifests

Raw Kubernetes manifests for a Volantis deployment. Apply them with `kubectl`.

For a templated install with values instead of hand-edits, use the Helm chart in
[`../helm`](../helm).

Everything lands in the `etri6g` namespace, except `mon-nad` (`monitoring`).

## Change these first

Applied as shipped, these will not work on your cluster:

| What | Where | Why |
|---|---|---|
| macvlan master `eth1`, subnet `192.168.0.0/24` | `nad.yaml`, `mon-nad.yaml` | Must match a real host interface |
| Static LAN IPs `.200`, `.210`, `.211` | `controller.yaml`, `gateway.yaml`, `pran.yaml` | Must be free on your subnet |
| `udr.url` | `nsm.yaml` | Points at the MongoDB node address |

`nsm.yaml` also carries SUCI private keys and the subscriber database URL. Replace them
before publishing anything based on this folder.

## Apply order

```bash
kubectl create namespace etri6g

kubectl apply -f nad.yaml           # lan network, needed by controller/gateway/pran
kubectl apply -f udr.yaml           # MongoDB
kubectl apply -f controller.yaml
kubectl apply -f gateway.yaml       # NFs register here, so it comes before them
kubectl apply -f services.yaml      # service definitions
kubectl apply -f nsm.yaml           # config hub, before the NFs that read it

kubectl apply -f udm.yaml -f ausf.yaml -f pcf.yaml
kubectl apply -f amf-10-100.yaml
kubectl apply -f smf.yaml
kubectl apply -f pran.yaml
```

Two orderings matter: the **gateway before any network function**, because that's the
registrar they contact at startup; and **nsm before the other NFs**, because it holds
the slice, AMF-set, and data-network config they read.

## Fixed addresses

Pinned in the manifests, so they need to be free in your cluster:

| | Address | Port |
|---|---|---|
| Controller | `10.100.100.10` | 8888 |
| Gateway | `10.100.100.1` | 7777 |
| MongoDB | `10.100.100.100`, NodePort 30001 | 27017 |
| Proxy-RAN NGAP | its lan address (`192.168.0.211`) | 38412 |
| Every NF | — | 9001 SBI, 7001 state |

## Files

### Mesh

| File | Creates |
|---|---|
| `nad.yaml` | The `lan` NetworkAttachmentDefinition (macvlan) |
| `controller.yaml` | Controller, Service, ServiceAccount, RBAC, config. Its only permission is to watch Services |
| `gateway.yaml` | Gateway, Service, ServiceAccount, RBAC, config. Carries `loc` labels used for locality |
| `services.yaml` | The service definitions — headless Services labelled `type: network-function` |

### Network functions

| File | Creates |
|---|---|
| `nsm.yaml` | NSM, the extended NSSF: slices, AMF sets, data networks, subscriber DB URL, SUCI profiles |
| `ausf.yaml`, `udm.yaml`, `pcf.yaml` | One deployment and config each |
| `amf-10-100.yaml` | AMF set 10-100, 3 replicas |
| `amf-10-101.yaml`, `amf-10-102.yaml` | Two more AMF sets |
| `damf.yaml` | Default AMF, for UEs attaching without an assigned slice. Being folded back into the AMF |
| `smf.yaml` | SMF for slice `1-010203`, 3 replicas |
| `pran.yaml` | Proxy-RAN — terminates NGAP/SCTP and exposes N2 as a service-based interface |
| `udr.yaml` | MongoDB, NodePort Service, PV/PVC/StorageClass. `hostPath`, so single-node only |

### Scaling

Two options per network function. **Apply one, not both** — two controllers driving the
same deployment will fight.

| File | Scales on |
|---|---|
| `amf-10-100-hpa.yaml`, `smf-hpa.yaml` | CPU, via the standard Kubernetes HPA. Needs metrics-server |
| `amf-autoscaler.yaml`, `smf-autoscaler.yaml` | Registered UEs and PDU sessions, via `NFAutoscaler` |

The custom scaler reads each pod's state endpoint on port 7001, located through the
`autoscaling.volantis/state-port` and `state-path` annotations on the deployment.

> The `NFAutoscaler` controller that reconciles these resources is not in this folder
> yet. The HPA files work with stock Kubernetes.

### Telemetry (optional)

| File | Creates |
|---|---|
| `monitoring.yaml` | The `nf` Service and a Prometheus `ServiceMonitor` that scrapes through it |
| `mon-nad.yaml` | The same `lan` network in the `monitoring` namespace, so Prometheus can reach it |

`monitoring.yaml` creates one headless Service, `nf`, selecting `plmnId: 001-01` — that
is **every network function in the PLMN**, not one per NF. The `ServiceMonitor` scrapes
`/metrics` on port 7001 through it every 5 seconds, so all NF metrics arrive on a single
target.

Notes:

- Needs the Prometheus Operator. The `ServiceMonitor` is picked up by a Prometheus
  with `release: prometheus`.
- The `nf` Service is labelled `type: nf`, deliberately **not** `type: network-function`
  — that label is what the mesh controller treats as a service definition. Don't align
  them.
- `mon-nad.yaml` assumes a `monitoring` namespace already exists.

`cpustat.yaml` is internal experiment tooling and isn't part of a deployment.

## Service definitions

`services.yaml` is where you control which instances serve a service. Each entry is a
headless Service whose selector is the membership:

```yaml
name: smf-001-01-1-010203
selector: {app: smf, plmnId: 001-01, slice: 1-010203}
```

Edit a selector and re-apply — membership changes with nothing rebuilt or restarted.
SMF pods also carry `region: seoul`, so adding that to the selector narrows the service
to one region. See [QUICKSTART.md](../../QUICKSTART.md).
