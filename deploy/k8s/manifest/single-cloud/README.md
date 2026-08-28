# Single-cloud deployment

One Kubernetes cluster, one gateway domain, PLMN `001-01`. Every network
function runs in the cluster **except the UPF**, whose data path needs the
`gtp5g` kernel module on a host. Controller, gateway and Proxy-RAN are published
with `LoadBalancer` Services.

```
                    cluster (namespace volantis)
  ┌──────────────────────────────────────────────────────────┐
  │  controller ── Lease ── K8s API ── Service objects        │
  │      │ (definitions + gateway registry)                   │
  │   gateway "cloud1"  ◀── registration/subscription ──┐     │
  │      │                                              │     │
  │   nsm  udm  ausf  pcf  damf         pran            │     │
  │   amf(10-100 ×2)  amf(10-101 ×1)                    │     │
  │   smf(1-010203)   smf(1-543210)      mongo (UDR)    │     │
  └──────┬──────────────┬────────────────────────┬──────┴─────┘
         │ LB :8888     │ LB :38412/SCTP         │ LB :7777
         │ (operator)   │                        │
         │              ▼                        ▼
         │        gNB (UERANSIM) ── N3/GTP-U ──▶ UPF ─ N6 ─ internet
         │           (host)                     (host, gtp5g)
```

**You are done when** the end-to-end test reports six passing stages:

```
Verdict
  pass    Requirements    pass    Subscribers    pass    NG Setup
  pass    N4              pass    Registration and PDU session
  pass    Data path
```

## Prerequisites

| | |
|---|---|
| cluster | Kubernetes with `kubectl` v1.21+, and a `LoadBalancer` provider. On minikube, run `minikube tunnel` in its own terminal — **not** under `sudo` |
| storage | a default StorageClass, for the UDR's PersistentVolumeClaim |
| a host for the UPF | the cluster machine will do. `gtp5g` ≥ 0.8.1 and < 0.9.20 loaded, `iptables`, and root |
| UERANSIM | `nr-gnb`, `nr-ue`, `nr-cli` for the gNB and the UEs. Verified on v3.3.0 |
| binaries | `bin/upf` and `bin/uegen` — see [`bin/README.md`](../../../../bin/README.md) |

Check the out-of-cluster half by name with `./deploy/deploy-external.sh check`.

## Quick start

Run everything from the repository root, with `kubectl` pointed at your cluster.

```bash
# 1. deploy, and wait for the workloads to come up
./deploy/k8s/k8s-deploy.sh -w

# 2. read the two addresses the out-of-cluster components need
kubectl -n volantis get svc gateway-svc pran-svc

# 3. open a path to the subscriber database
kubectl -n volantis port-forward svc/udr-mongo 27017:27017 &

# 4. the UPF, a gNB and a UE, as one end-to-end test
sudo ./deploy/deploy-external.sh e2e \
    --pran <pran-svc EXTERNAL-IP> --gateway <gateway-svc EXTERNAL-IP> \
    --probe <an address this host can reach> \
    --pod-cidr 10.244.0.0/16 --node-ip "$(minikube ip)"
```

Tear it down with `sudo ./deploy/deploy-external.sh stop` and
`./deploy/k8s/k8s-deploy.sh -D -y`.

> Note: three things trip up a first run. `--pod-cidr` and `--node-ip` are needed
> on any single-node cluster (§2). A MongoDB already on 27017 makes step 3
> forward nothing useful, and every UE is then rejected
> ([external](../../../external/README.md)). And if the UPF or gNB is on a
> *different* machine, the addresses from step 2 do not reach it (§2.1).

---

## 1. Deploy

```bash
./deploy/k8s/k8s-deploy.sh                  # the default tag, v0.1.1
./deploy/k8s/k8s-deploy.sh -t v0.2.0        # that tag instead
./deploy/k8s/k8s-deploy.sh -n -t v0.2.0     # render, show the images and the diff, apply nothing
./deploy/k8s/k8s-deploy.sh -w -t v0.2.0     # and wait for the workloads to come up
```

Use the script rather than `kubectl apply -k`: the manifests name
`volantis-<nf>` with no registry, and the script is what supplies one. To read
what would be applied without applying it, render the base with `kubectl
kustomize deploy/k8s/manifest/single-cloud/` — **`-k`, not `-f`**, since the
directory carries a `kustomization.yaml`.

Each network function is `ghcr.io/reogac/volantis-<nf>:<tag>`. The packages are
public, so **pulling needs no registry account** — the `reogac` in the path is a
GHCR namespace, not a login. To pull from a mirror or a build of your own, edit
`IMAGE` at the top of `k8s-deploy.sh`; it is the only place an image prefix is
written.

Install it as a Helm release instead if you prefer —
[`../../helm/`](../../helm/README.md) covers what differs, including why `helm
--wait` is the wrong thing to reach for:

```bash
./deploy/k8s/k8s-deploy.sh --engine helm -t v0.2.0
```

**Order does not matter**, which is why nothing here is numbered. Every
component retries its way into the mesh instead of requiring what it depends on
to already exist: a gateway started before the controller retries forever, and a
controller that restarts is repopulated by the gateways replaying into it; an NF
started before its gateway waits for it; an NF started before NSM retries its
configuration pull indefinitely rather than exiting.

Until a pull succeeds the instance is registered but **not selectable**, so
nothing is routed to it: `/ready` and `/state` answer `503` with `"active":
false`, and `mesh_sbi_active` reads 0. Starting out of order costs start-up
latency, not a failed deployment.

> Note: use immutable version tags. With `imagePullPolicy: IfNotPresent`,
> re-pushing a moving tag and re-applying gets you the *old* image, and no error.

### 1.1 The three published addresses

Read them back once the Services have them:

```bash
kubectl -n volantis get svc ctrl-svc gateway-svc pran-svc
```

| Service | port | who needs the address |
| --- | --- | --- |
| `ctrl-svc` | 8888 | you — `/mon/services`, `/mon/endpoints`, the OAM API |
| `gateway-svc` | 7777 | the UPF, as its `mesh.registrar` |
| `pran-svc` | 38412 **SCTP** | the gNB, as its `amfConfigs[].address` |

Hand two of them to the out-of-cluster components, once:

```bash
./deploy/deploy-external.sh check \
    --pran <pran-svc EXTERNAL-IP> --gateway <gateway-svc EXTERNAL-IP>
```

Nothing inside the cluster needs any of them. The one gateway advertises only
`local`, so the controller probes it through cluster DNS, and an NF pod reaches
the gateway the same way (`gateway-svc.volantis.svc.cluster.local:7777`).

> Note: on minikube the addresses stay `<pending>` until `minikube tunnel` runs,
> and what it assigns is routable **on that host only** — §2.1 and §8.

### 1.2 Check the mesh came up

```bash
curl http://<ctrl-svc EXTERNAL-IP>:8888/mon/services    # the definitions in force
curl http://<ctrl-svc EXTERNAL-IP>:8888/mon/endpoints   # who registered
```

> Note: `/mon/services` shows four definitions you did not write — `ctrl-svc`,
> `gateway-svc`, `pran-svc`, `udr-mongo`. In Kubernetes the definition store *is*
> the namespace's `Service` objects, and any Service with a selector becomes one.
> They are inert. Nothing to fix.

---

## 2. Networking this deployment assumes

A single-node lab cluster usually cannot route between the host and the pod
network, and the UPF needs it in both directions. Add the route before you start
the UPF:

```bash
# on the UPF host: reach pod IPs through the node
sudo ip route add <pod-cidr> via <node-ip>          # minikube: 10.244.0.0/16 via $(minikube ip)
```

`deploy-external.sh` does this for you when you pass `--pod-cidr` and
`--node-ip`, and removes it on `stop`.

The UPF is in the cluster's gateway domain but not in the cluster, so its SBI
traffic crosses the pod-network boundary **in both directions**:

| from | to | why |
| --- | --- | --- |
| UPF host | `gateway-svc` external address :7777 | registration, subscription, control plane |
| UPF host | pod IPs :9001 | N4 to the SMFs — resolution is client-side and direct |
| pods | UPF host :9001, :7001 | N4 back, plus the gateway's liveness ping to `:7001` |

The first is what the LoadBalancer provides; the other two are what that route is
for.

If the host's address as seen from the pods is not the address it would choose
itself — a NAT, or a multi-homed host — set it explicitly rather than letting the
agent infer it:

```json
"mesh": {
  "registrar": "<gateway-svc EXTERNAL-IP>:7777",
  "registered": { "address": "THE_ADDRESS_PODS_SEE" }
}
```

> Note: both ports matter. The gateway needs the **agent** port (7001) for
> liveness and updates, so forwarding only the SBI port leaves the NF registered
> but unreachable, and it is evicted after ~90 s of missed pings.

The user plane crosses no such boundary. N3 runs gNB → UPF directly, both outside
the cluster, and N2 runs gNB → `pran-svc` inwards only. `nr-gnb` and the UPF both
want GTP-U/2152 and can share a host only if each binds its own address, so give
them two addresses or two machines.

### 2.1 Reaching the cluster from another machine

If the UPF or the gNB runs on a *different* machine from the cluster, publish the
three Services on the cluster machine's own LAN address:

```bash
# on the machine running the cluster
GW=$(kubectl -n volantis get svc gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
CTRL=$(kubectl -n volantis get svc ctrl-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PRAN=$(kubectl -n volantis get svc pran-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp  --dport 7777  -j DNAT --to-destination $GW:7777
sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp  --dport 8888  -j DNAT --to-destination $CTRL:8888
sudo iptables -t nat -A PREROUTING -i <lan-if> -p sctp --dport 38412 -j DNAT --to-destination $PRAN:38412
```

Add the return route, which is §2's route one hop longer:

```bash
# on the UPF host
sudo ip route add 10.244.0.0/16 via <cluster machine LAN address>

# on the cluster machine
sudo ip route add 10.244.0.0/16 via $(minikube ip)
sudo sysctl -w net.ipv4.ip_forward=1
```

Then give the out-of-cluster components the **cluster machine's** address rather
than any `EXTERNAL-IP`, and set the UPF's `registered.address` to its own LAN
address:

```bash
./deploy/deploy-external.sh check --pran 192.168.1.10 --gateway 192.168.1.10
```

Two more rules, each for one situation:

```bash
# a UPF or gNB sharing a machine with the cluster dials that machine's own
# address, and PREROUTING does not run for locally generated packets
sudo iptables -t nat -A OUTPUT -d <this machine's LAN address> -p tcp --dport 7777 \
     -j DNAT --to-destination $GW:7777

# the SCTP rule above needs this if iptables refuses -p sctp
sudo modprobe nf_conntrack_proto_sctp
```

Give the UPF and the gNB a machine of their own and the first does not arise.

> Note: pin what those rules point at. An `EXTERNAL-IP` here *is* the Service's
> ClusterIP, and a delete-and-re-apply allocates a new one — leaving the rules
> aimed at addresses nothing answers on, with no error to say so. Set
> `spec.clusterIP` on the three Services. Why none of this is needed on a real
> load balancer: §8.

**`uegen` still needs the UDR**, and the UDR stays ClusterIP. Provision the
subscribers from the cluster machine, where `kubectl port-forward` reaches it —
the gNB and the UPF never touch the database.

---

## 3. The UPF, a gNB and a UE

The UPF is the only network function outside the cluster. Proxy-RAN moved in,
because all it needs from outside is a reachable SCTP port and Kubernetes has
carried SCTP Services since 1.20; the UPF cannot follow, because its data path
needs `gtp5g` on the host. A UERANSIM gNB and the UEs are outside for a different
reason — they are what the deployment is tested *with*, not part of it.

### 3.1 What has to agree with the cluster

Two values, both in `pran.yaml` rather than on a host:

- **`amfRegion: 10`** must be the region half of the AMF set ids in NSM
  (`10-100`, `10-101`). PRAN pulls the slice list for *its* region and refuses to
  open its SCTP listener if no set matches — so a mismatch shows up as a
  `pran-dep` pod that stays `Running` and never `Ready`, not as a gNB error.
- **`transportNetworks: ["tran1"]`** in PRAN and the UPF's `--tran` must both name
  a transport network NSM declares. The SMF's path search starts from the faces
  PRAN names and ends at an anchor UPF; if the names do not line up it finds no
  source face and session establishment fails.

A third has to agree across the PLMN: the SUCI **public** keys the subscribers are
provisioned against are the halves of the private keys in `nsm.yaml`. Get that
wrong and authentication fails with a SUCI de-concealment error.

Everything else is this deployment's default already: transport network `tran1`,
no `cloud` label, both slices on the `n6` face. The gNB's `--tac` defaults to `1`
while PRAN's own `tac` pod label is `001`; nothing cross-checks the two, and PRAN
records whatever NG Setup sends.

### 3.2 Run it

Take the two addresses from §1.1, open a path to the database, and run the test:

```bash
kubectl -n volantis port-forward svc/udr-mongo 27017:27017 &

sudo ./deploy/deploy-external.sh e2e \
    --pran <pran-svc EXTERNAL-IP> --gateway <gateway-svc EXTERNAL-IP> \
    --probe <an address this host can reach>
```

It reports a verdict per stage — subscribers, NG Setup, N4, registration, PDU
session, data path — so a failure names the stage it happened in. The same two
addresses drive the shot-by-shot form (`check`, `subscribers`, `gnb`, `upf`,
`ue 1`), and they are remembered after the first shot.

**This is where this README stops.** The UPF, the gNB, the UEs and the
provisioning of subscribers are the same in every deployment, so they live once
in [`../../../external/`](../../../external/README.md) — how to run them, what
they need of a host, and the several things that go wrong quietly.

Two things this deployment changes about those arguments:

- **On minikube, add `--pod-cidr 10.244.0.0/16 --node-ip "$(minikube ip)"`.** The
  UPF pulls its data networks from NSM, and NSM is a pod — without a route to the
  pod network it registers and never becomes ready. §2.
- **From another machine, `--pran` and `--gateway` are the cluster machine's own
  LAN address**, not either `EXTERNAL-IP`. §2.1.

---

## 4. Change configuration

| what | how |
| --- | --- |
| service definitions | edit `service-definitions.yaml` and `kubectl apply`. The controller watches Services and reconciles every 60 s; agents pick the change up on their next poll. Or use the OAM API — same store, same path. |
| an NF's own config | edit its ConfigMap and `kubectl rollout restart` its Deployment |
| **NSM's config** | edit `nsm.yaml` and **restart NSM** — its configuration is immutable for the life of the process |

Every NF re-pulls from NSM periodically, so an edit reaches all of them without a
restart once NSM is carrying it. A refresh never replaces a good configuration
with an insufficient one: if an edit is rejected, the running instances keep what
they had and say so in the log.

---

## 5. Scale AMF and SMF

### 5.1 What the scaling unit is, and why it is not the instance

Both are stateful per context and there is no shared state store: an AMF holds
its UEs' contexts in its own process, an SMF holds its PDU sessions in its own.
So scaling cannot mean "put a load balancer in front of N identical replicas" —
signaling for one UE has to keep reaching the *same* instance. The mesh provides
that as **session affinity**, and each NF has a different key for it:

**AMF — the unit is the AMF set.** A UE that comes back presents a GUTI, and the
AMF id inside it is `region + set + pointer`. PRAN takes that apart, resolves the
service identity `{app: amf, plmnId: 001-01, amfset: 10-100}` and then pins the
*instance* whose id is the AMF pointer. Instances of one set therefore share
region and set and must differ in pointer — which NSM allocates, one per
instance, at registration.

**SMF — the unit is the slice.** The AMF resolves `{app: smf, plmnId: 001-01,
slice: 1-010203}` and pins one producer for the session's lifetime, because the
definition is `stateful`. Each SMF instance claims one UE IP **segment** per
address space from NSM at start-up — a real sub-prefix such as `10.60.32.0/22`,
not an index — so instances of a slice hand out disjoint UE addresses without
coordinating.

In both cases the label on the pod (`amfset`, `slice`) and the selector in the
service definition are the same key. That is what makes the next section a
one-liner.

### 5.2 Scale out

```bash
kubectl -n volantis scale deploy/amf-10-100-dep --replicas=6
kubectl -n volantis scale deploy/smf-1-010203-dep --replicas=3
```

Nothing else changes — no definition edit, no NSM edit, no restart of anything.
A new pod:

1. registers with the gateway, which reads its **pod labels** through the API
   server (this is why the gateway has `get pods` RBAC);
2. is matched by subset into every definition whose selectors it satisfies — an
   AMF of set 10-100 joins both `amf-001-01-10-100` and the set-less
   `amf-001-01`;
3. pulls its configuration from NSM, then claims what it needs — an AMF pointer
   (AMF) or a UE IP segment per address space (SMF);
4. calls `ActivateSbi` with that identity, at which point `/ready` turns 200 and
   consumers' load balancers start selecting it.

Watch step 4 rather than the pod's `Running` state:

```bash
kubectl -n volantis get pods -l app=amf
curl http://<ctrl-svc EXTERNAL-IP>:8888/mon/endpoints
```

> Note: a pod that is `Running` but not `Ready` is an instance that has not
> finished its NSM pull. It is registered and **not selectable** — the readiness
> probe in these manifests reads exactly that.

### 5.3 The ceilings

| limit | value | what happens at it |
| --- | --- | --- |
| instances per AMF set | **64** | the AMF pointer is 6 bits. The 65th instance is refused a pointer and never activates; NSM logs "all 64 pointers are held". |
| AMF sets | 64 per region, and each needs its own definition | see §5.4 |
| SMF instances per address space | **how many segments it holds** — `segmentLength: 22` over a /16 is 64 | counted across *all* slices reaching that routing domain, not per slice. An instance granted no segment still activates if it has a usable data network; PDU sessions needing an address from that space are rejected until one is granted, and the next refresh asks again. |
| definition count | no limit worth naming | |

Released resources come back: NSM reclaims an SMF's pool and an AMF's pointer
when the endpoint leaves the mesh, and defers reuse of a pointer for a cooldown
so a restarting instance does not immediately inherit another's identity. That
reclamation is not instant — the mesh notices a departure through liveness (30 s
ping × tolerance 3, so up to ~90 s) unless the process deregisters cleanly.

### 5.4 Add an AMF set, or a slice

Scaling *out* needs one command. Adding a new **set** or **slice** needs three
things to agree, and all three are the same key.

New AMF set `10-102`:

1. **NSM** — add it to `amfSets` in `nsm.yaml`, with the slices it serves, then
   restart NSM. Without this, DAMF never selects the set and its instances are
   never allocated a pointer.
2. **A definition** — a headless `Service` in `service-definitions.yaml` with
   `spec.selector` = `{app: amf, plmnId: 001-01, amfset: 10-102}`. Without it
   PRAN cannot resolve that set.
3. **A Deployment** — copy `amf-10-101.yaml` and change the set id in the
   Deployment name, the ConfigMap name, `"amfSet"` in the JSON, and the `amfset`
   pod label. Add the new file to `resources:` in `kustomization.yaml`, or
   `apply -k` will not see it.

The region half must stay `10`, to match PRAN's `amfRegion`.

A new slice works the same way: add it to `slices` (and to some `amfSets` entry)
in NSM, add a `Service` with selector `{app: smf, plmnId: 001-01, slice: <sst-sd>}`,
and add an SMF Deployment carrying that `slice` label and the matching `"slice"`
object in its config. The `slice` label is `sst-sd` — sst=1 sd=010203 is
`1-010203`.

> Note: what is *not* a step — no network function's code changes, and no NF is
> told about the new set or slice.

### 5.5 Scale in — read this first

**Scaling in drops live contexts.** There is no shared state store: a terminated
AMF takes its UEs' contexts with it, a terminated SMF takes its PDU sessions.
Those UEs have to re-attach. This is a known limitation, not a bug, and it
applies equally to instance failure.

`kubectl scale --replicas=` down is therefore only safe when the instances it
picks are idle — and you do not get to pick, the Deployment does. To retire
capacity gracefully, split the set into two Deployments that differ in one extra
label, and **drain** one of them:

```yaml
# on the amf-001-01-10-100 Service in service-definitions.yaml
metadata:
  annotations:
    mesh.volantis.io/definition: |
      {
        "stateful": true,
        "groups": {
          "serving":  { "selectors": { "wave": "a" } },
          "retiring": { "selectors": { "wave": "b" }, "drain": true }
        },
        "routes": [
          { "destinations": [ { "group": "serving" }, { "group": "retiring" } ] }
        ]
      }
```

A drained group leaves selection everywhere but keeps its endpoints in the
service, so **existing pins keep working while no new UE lands there**. When
`uesRegistered` on the wave-b pods reaches zero, scale that Deployment to 0.

> Note: two things about drain that bite. **The route is what makes it work** —
> `drain` is evaluated when a route picks a destination, so a group flagged
> `drain: true` with no route targeting it does nothing at all. And **the route
> is binding**: a matched route that finds no producer *refuses* the request
> rather than falling back, unless you set `"fallthrough": true` — so draining
> every group of a route takes the service down.

### 5.6 Autoscaling

Scaling here is **capacity-driven, not CPU-driven**. A signaling NF at 30% CPU
can still be at its UE ceiling. The signal the mesh publishes is `/state` on the
agent port:

```bash
kubectl -n volantis port-forward deploy/amf-10-100-dep 7001:7001
curl localhost:7001/state
# {"uesCreated":812,"uesReleased":390,"uesRegistered":422,"registerRate":37,"draining":false}
```

`uesRegistered` and `sessionsEstablished` are the occupancy figures. Scale out at
**50% of provisioned capacity**, which leaves room for a set to absorb the load
of a lost instance. An instance that has not activated answers `/state` with
`503` and `{"active": false}` — deliberately, so an unconfigured replica cannot
report full idle capacity.

The mesh publishes the signal and never talks to an autoscaler; the actuator
stays outside. To wire one up, scrape `/metrics` on port 7001 with Prometheus,
expose the occupancy as a custom metric with `prometheus-adapter`, and point an
HPA at it:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: amf-10-100-hpa
  namespace: volantis
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: amf-10-100-dep
  minReplicas: 2
  maxReplicas: 64          # the AMF pointer space; see §5.3
  metrics:
    - type: Pods
      pods:
        metric:
          name: amf_ues_registered     # via prometheus-adapter
        target:
          type: AverageValue
          averageValue: "500"          # 50% of a 1000-UE provisioned capacity
  behavior:
    scaleDown:
      # scale-in drops contexts (§5.5); make the autoscaler reluctant, and
      # prefer the drain procedure for anything deliberate
      stabilizationWindowSeconds: 900
      policies:
        - type: Pods
          value: 1
          periodSeconds: 600
```

> Note: this HPA is **not applied by these manifests**. It needs a metrics
> pipeline this deployment does not install, and an occupancy target measured on
> your hardware rather than guessed. Treat it as the shape of the answer.

---

## 6. What is in here

| file | what it creates |
| --- | --- |
| `namespace.yaml` | namespace `volantis` |
| `controller.yaml` | controller + RBAC + `LoadBalancer` on 8888 |
| `gateway.yaml` | gateway `cloud1` + RBAC + `LoadBalancer` on 7777 |
| `udr.yaml` | MongoDB standing in for the UDR (ClusterIP) |
| `nsm.yaml` | NSM and the system-wide configuration |
| `udm.yaml`, `ausf.yaml`, `pcf.yaml`, `damf.yaml` | one replica each |
| `amf-10-100.yaml`, `amf-10-101.yaml` | one Deployment per **AMF set** |
| `smf-1-010203.yaml`, `smf-1-543210.yaml` | one Deployment per **slice** |
| `pran.yaml` | Proxy-RAN + a `LoadBalancer` carrying **SCTP** on 38412 |
| `service-definitions.yaml` | the service catalogue, as headless `Service` objects |
| `kustomization.yaml` | what the deployment applies |

The UPF, a gNB and the UEs are not here. They run outside a cluster and are the
same in every deployment, so they live once in
[`../../../external/`](../../../external/README.md).

Deliberately out of scope, to keep this deployment small:

| left out | where it is instead |
| --- | --- |
| SEPP and roaming | not in this repository — one PLMN, no N32 |
| controller HA (2 replicas + Lease) | [`../multi-cloud/central/controller.yaml`](../multi-cloud/central/controller.yaml) |
| gateway HA | not implemented anywhere |
| TLS / mTLS | every process takes `--cert/--key/--pem` — give all three or none |

Everything here runs in cleartext, and each process logs a warning at start-up
saying so. Do not put it on a network you do not control.

For the same core with no cluster at all, see
[`../../../local/`](../../../local/README.md). For three clusters sharing one
mesh, [`../multi-cloud/`](../multi-cloud/README.md).

---

## 7. When something does not work

| symptom | look at |
| --- | --- |
| NF pod `Running`, never `Ready` | its NSM pull. `kubectl logs`; check NSM is up and that `udr` in NSM's config resolves |
| `no such service` / `ReasonNoService` | `/mon/services` on the controller. The request's attribute set must equal a definition's selectors **exactly** — one extra or missing key and nothing matches |
| service exists, no producer | `/mon/endpoints`. Membership is a *subset* test against pod labels; a typo in a pod label silently un-memberships the pod |
| gateway will not register | the controller's log. It probes the gateway's advertised address and refuses if it does not answer *as itself*; check `advertise.local` and that `id: cloud1` is in the controller's `gateways` allow-list |
| the UPF registers, then vanishes after ~90 s | the gateway cannot reach its **agent** port 7001. §2 |
| `pran-dep` `Running`, never `Ready` | its NSM pull found no AMF set in region 10. `amfRegion` in `pran.yaml` must match the region half of NSM's `amfSets`. Until it does, no SCTP listener opens and every gNB times out |
| the UPF or gNB is on another machine and nothing connects | the `EXTERNAL-IP`s `minikube tunnel` assigns are ClusterIPs, routable on the cluster machine only. §2.1 |
| gNB gets no answer on 38412 | `kubectl -n volantis get svc pran-svc` — a `<pending>` EXTERNAL-IP means no LoadBalancer provider is publishing it. If it has one, check the node's kernel has the `sctp` module |
| authentication fails on the first UE | the SUCI public keys the subscribers were provisioned against must be the halves of the private keys in `nsm.yaml`, and the subscriber must exist in the UDR. §3.1 |
| session establishment fails, "Cannot find any srcFaces" | PRAN's `transportNetworks` and the UPF's `interfaces[].network` do not name the same transport network |
| UE registers, then never asks for a session | its profile has no `sessions:` — `uegen` was run without `-template`. [`../../../external/`](../../../external/README.md) |
| UE has `uesimtun0`, no traffic passes | it is not in its own network namespace, or the namespace's default route is still the veth. [`../../../external/`](../../../external/README.md) |
| UPF logs `Anchored data networks: []` | no `n6` face serves a DNN that NSM returned; it will accept no session. [`../../../external/`](../../../external/README.md) |
| both SMFs `Running`, never `Ready`, NSM logs "No data network serves slice" | NSM's `slices[].dataNetworks` does not name a declared data network |
| `udr-dep` `Pending`, `mongodb-pvc` unbound | the cluster has no default StorageClass, or a `Released` PersistentVolume from an earlier deployment is holding the name. UDM, PCF and both SMFs will not become ready without the UDR |

---

## 8. Why it is like this

Skip until you need it.

**One gateway domain.** Every endpoint — the pods and the one out-of-cluster
process alike — is *local* to every other, so no SBI call takes the gateway's
proxy path. The gateway is a registry here, not a data path. That is what lets
one gateway serve both the cluster and the UPF, and it is where §2's routing
requirement comes from.

**Addresses are literal, not names.** Nothing in the mesh verifies an address, so
a wrong one registers cleanly, stays healthy and fails every request. One place
to be wrong beats a name plus a lookup that can also be wrong. If your provider
lets you choose the address rather than assigning one, pin it with
`spec.loadBalancerIP` and the substitution becomes a one-time edit.

**Why `minikube tunnel`'s addresses do not reach another machine.** It gives you
exactly one thing: `EXTERNAL-IP`s that are the Services' own ClusterIPs, out of
`10.96.0.0/12`, made to mean something by a route installed on that host alone.
The node is no better — on the docker driver it sits on a bridge
(`192.168.49.2`, host side `192.168.49.1`) that exists only in that machine's
routing table. Two host-local layers, neither reachable from the LAN.

`DNAT` in `PREROUTING` works because it rewrites the destination and then hands
the packet to the host's ordinary routing decision, which is where the tunnel's
route applies. Replies need no `SNAT`: the node's default route is the host, so
the host's conntrack sees them and undoes the translation.

**Without `minikube tunnel` at all.** A `type: LoadBalancer` Service allocates a
node port as well, and `<node>:<nodePort>` answers with no tunnel process
running. Pin `spec.ports[].nodePort` for the same reason as the ClusterIPs:

```bash
GW_NP=$(kubectl -n volantis get svc gateway-svc -o jsonpath='{.spec.ports[0].nodePort}')
sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp --dport 7777 \
     -j DNAT --to-destination $(minikube ip):$GW_NP
```

**MetalLB is not the answer on minikube's docker driver.** In L2 mode it answers
ARP for its pool, and it would be answering *inside* the docker bridge, where the
LAN never hears it. It becomes the right answer once the node is genuinely on the
LAN — `--driver=none`, or a VM with a *bridged* adapter — which is also the point
at which none of §2.1 is needed.
