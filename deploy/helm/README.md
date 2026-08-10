# Volantis chart

Deploys the mesh, the network functions, and the service definitions.

```bash
helm install vol deploy/helm -n etri6g --create-namespace
```

Defaults reproduce `deploy/manifest/` as shipped. Everything else is a values override.

## Common changes

**Point at a different registry.** The default is `ghcr.io/reogac/volantis`:

```bash
--set image.registry=my-registry.example.com/volantis --set image.tag=v0.1.0
```

**Match your host interface.** `nad.yaml` builds a macvlan on `eth1`:

```bash
--set multus.nad.master=ens3 --set multus.nad.subnet=10.10.0.0/24
```

**Scale a set:**

```bash
--set amf.sets[0].replicas=5
```

**Turn on autoscaling.** Two kinds, one at a time:

```bash
# capacity-driven: registered UEs and PDU sessions
--set autoscaler.enabled=true --set autoscaler.kind=nfautoscaler

# stock Kubernetes HPA on CPU
--set autoscaler.enabled=true --set autoscaler.kind=hpa
```

`nfautoscaler` needs the NFAutoscaler controller, which isn't in this chart yet. `hpa`
needs metrics-server and works with stock Kubernetes. The chart emits one or the other,
never both — two controllers driving the same deployment fight each other.

## What you get

| Values key | Objects |
|---|---|
| `multus.nad.create` | The `lan` NetworkAttachmentDefinition |
| `mesh.controller.enabled` | Controller, its Service, ServiceAccount, RBAC, config |
| `mesh.gateway.enabled` | Gateway, its Service, ServiceAccount, RBAC, config |
| `mongodb.enabled` | MongoDB, NodePort Service, PV/PVC/StorageClass |
| `nsm.enabled` | NSM and its config Secret |
| `simpleNFs.*.enabled` | AUSF, UDM, PCF |
| `amf.sets[]` | One Deployment and ConfigMap per set |
| `smf.slices[]` | One Deployment and ConfigMap per slice |
| `pran.enabled` | Proxy-RAN |
| `serviceDefinitions.enabled` | The headless Services the controller watches |
| `autoscaler.enabled` + `kind` | An `NFAutoscaler` **or** an `HorizontalPodAutoscaler` per AMF set and SMF slice |

## Service definitions

Service definitions are generated from what you deploy, so they can't drift from the
AMF sets and SMF slices you declared.

To narrow membership — for example to keep signalling inside one cloud — add
`selectorExtra` to a slice:

```yaml
smf:
  slices:
    - name: slice1
      key: 1-010203
      sst: 1
      sd: "010203"
      replicas: 3
      extraLabels:
        region: seoul      # goes on the pods
      selectorExtra:
        region: seoul      # goes in the service definition selector
```

`extraLabels` labels the pods; `selectorExtra` narrows the service definition to them.
Set the second without the first and the service has no endpoints.

## Multi-cloud

Install once per cluster. The central cluster runs the controller, the subscriber
store, and the shared functions; each edge runs a gateway, Proxy-RAN, and local AMF and
SMF instances. See [`values-edge.yaml`](values-edge.yaml).

Two things must be right for an edge:

- `mesh.gateway.controllerAddr` — the controller's **lan** address, since its cluster IP
  means nothing from another cluster.
- `serviceDefinitions.enabled: false` — declare them once, centrally.

## Notes

- Service definitions render for every declared AMF set, including sets with
  `replicas: 0`. That's deliberate: the service exists with no endpoints, so scaling up
  later needs no re-apply.
- `nsm` config renders into a **Secret**, not a ConfigMap, because it carries the
  subscriber database URL and SUCI keys. Don't commit real private keys — pass them at
  install time.
- The MongoDB volume is a `hostPath` with no provisioner, so it's single-node only.
  Set `mongodb.persistence.create=false` to skip it.
