# Quickstart

Bring up a Volantis control plane on one Kubernetes cluster and register UEs.

No UPF, so registration works but PDU sessions don't. Add the user plane afterwards with
[`deploy/config/upf.json`](deploy/config/upf.json) — it runs on the host, not in the
cluster.

Everything below runs in the `etri6g` namespace.

## What you need

| | Notes |
|---|---|
| A Kubernetes cluster | Minikube works. The manifests pin cluster IPs in `10.100.100.0/24`, which is inside minikube's default service CIDR |
| [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) | The controller, gateway, and Proxy-RAN attach to a second network |
| A spare host interface | `nad.yaml` builds a macvlan on `eth1` over `192.168.0.0/24`. Change both if your interface or subnet differs |
| `kubectl` | |
| [StormSIM](https://github.com/lvdund/StormSIM) or [UERANSIM](https://github.com/aligungr/UERANSIM) | To drive signaling |

**Images aren't published yet.** The manifests point at `ghcr.io/reogac/volantis`, but
nothing is there so far, so pods will fail to pull. Build the images and push them to a
registry your cluster can reach first — see [images/](images/).

## 1. Namespace and network

```bash
kubectl create namespace etri6g
kubectl apply -f deploy/manifest/nad.yaml
```

`nad.yaml` defines the `lan` NetworkAttachmentDefinition. The controller, gateway, and
Proxy-RAN take static addresses on it, which is how the gNB reaches Proxy-RAN over SCTP
and how clusters reach each other.

## 2. Subscriber database

Volantis has no UDR. The UDM reads subscribers from MongoDB directly.

```bash
kubectl apply -f deploy/manifest/udr.yaml
```

This creates the MongoDB deployment, a NodePort on 30001, and a `hostPath` volume — so
it's single-node only as written.

## 3. Mesh

```bash
kubectl apply -f deploy/manifest/controller.yaml
kubectl apply -f deploy/manifest/gateway.yaml
kubectl -n etri6g rollout status deploy/ctrl-dep
kubectl -n etri6g rollout status deploy/gateway-se-dep
```

| | Port | ClusterIP |
|---|---|---|
| Controller | 8888 | 10.100.100.10 |
| Gateway | 7777 | 10.100.100.1 |

Network functions register with the **gateway** (`mesh.registrar` in every NF config),
which relays to the controller.

## 4. Service definitions

```bash
kubectl apply -f deploy/manifest/services.yaml
```

These are headless Kubernetes Services labeled `type: network-function`. Each one names
a service and selects the instances that serve it. The controller watches them — that's
its only RBAC permission.

```bash
kubectl -n etri6g get svc -l type=network-function
```

## 5. Network functions

Config hub first — `nsm` holds the slices, AMF sets, data networks, and the MongoDB URL
that the other functions read:

```bash
kubectl apply -f deploy/manifest/nsm.yaml
```

Then the rest:

```bash
kubectl apply -f deploy/manifest/udm.yaml
kubectl apply -f deploy/manifest/ausf.yaml
kubectl apply -f deploy/manifest/pcf.yaml
kubectl apply -f deploy/manifest/amf-10-100.yaml
kubectl apply -f deploy/manifest/smf.yaml
kubectl apply -f deploy/manifest/pran.yaml
```

Check everything is up and registered:

```bash
kubectl -n etri6g get pods
kubectl -n etri6g logs deploy/ctrl-dep | grep -i regist
```

`amf-10-101.yaml` and `amf-10-102.yaml` add two more AMF sets if you want them.

## 6. Register UEs

Proxy-RAN terminates NGAP on port 38412 at its `lan` address (`192.168.0.211` as
shipped). Point your emulator there.

```bash
kubectl -n etri6g logs -l app=amf --tail=50
```

<!-- TODO: add a StormSIM profile for this scenario and the UERANSIM gnb/ue yaml. -->

## 7. Scale

The AMF scales with plain Kubernetes. No SCTP-aware load balancer, no peer
reconfiguration:

```bash
kubectl -n etri6g scale deploy/amf-10-100-dep --replicas=5
kubectl -n etri6g get endpoints amf-001-01-10-100
```

New pods carry the same labels, so the service definition picks them up and they start
receiving signaling. Existing UE contexts stay on the instance holding them.

For autoscaling instead of manual scaling, pick one of two. **Apply one, not both** —
two controllers driving the same deployment will fight.

Capacity-driven, on registered UEs and PDU sessions:

```bash
kubectl apply -f deploy/manifest/amf-autoscaler.yaml
kubectl apply -f deploy/manifest/smf-autoscaler.yaml
```

These are `NFAutoscaler` resources — 5000 UEs per AMF pod, 5000 sessions per SMF pod,
read from each pod's state endpoint on port 7001.
<!-- TODO: the NFAutoscaler controller itself isn't in deploy/manifest/. Add it. -->

Or the stock Kubernetes HPA, on CPU:

```bash
kubectl apply -f deploy/manifest/amf-10-100-hpa.yaml
kubectl apply -f deploy/manifest/smf-hpa.yaml
```

These need metrics-server, and they work with stock Kubernetes today — the
`NFAutoscaler` controller isn't published yet.

## 8. Change which instances serve a service

Membership is a label selector. SMF pods carry `region: seoul`, so you can narrow the
SMF service to one region by editing its selector:

```bash
kubectl -n etri6g get pods -l app=smf --show-labels
kubectl -n etri6g get endpoints smf-001-01-1-010203
```

Add `region: seoul` to the `smf-001-01-1-010203` selector in
`deploy/manifest/services.yaml`, re-apply, and the endpoint list changes. No network
function is rebuilt, restarted, or reconfigured.

<!-- TODO: document per-request routing policy — mapping a request attribute such as
     Proxy-RAN's `tac` to an instance label such as the gateway's `loc`. It isn't in
     these manifests; controller.json is empty. -->

## 9. Telemetry (optional)

```bash
kubectl apply -f deploy/manifest/mon-nad.yaml
kubectl apply -f deploy/manifest/monitoring.yaml
```

This creates one headless Service, `nf`, covering every network function in the PLMN,
and a `ServiceMonitor` that scrapes `/metrics` on port 7001 through it. Needs the
Prometheus Operator.

## Clean up

```bash
kubectl delete namespace etri6g
```

## Next

- **PDU sessions** — run a UPF on the host with
  [`deploy/config/upf.json`](deploy/config/upf.json). It needs the `gtp5g` kernel module,
  which is why it isn't a cluster workload. Note it declares its own mesh labels, since
  it has no pod labels to read.
- **Multi-cloud** — gateways federate clusters over mTLS. Guide coming in a later
  release.
