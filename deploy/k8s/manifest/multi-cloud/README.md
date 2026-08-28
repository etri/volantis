# Multi-cloud deployment — one central cloud, two edges

Three Kubernetes clusters, one mesh. The central cloud holds the control-plane
NFs everything shares; each cloud — central included — holds an AMF and an SMF of
every set and slice, plus a PRAN behind an SCTP LoadBalancer. The UPF is the one
network function that runs outside a cluster, on a host beside it.

```
                        ┌──────────────────────── central cloud ─────────────────────────┐
                        │                                                                │
   gNB(central) ────────┼─▶ pran (LB:38412/SCTP)                                         │
                        │   controller×2 (LB:8888)  nsm  udm  ausf  pcf  udr(mongo)      │
   UPF(central) ────────┼─▶ gateway (LB:7777)  ◀──┐                                      │
   tran-central         │        ▲                │  damf  amf-10-100  amf-10-101        │
                        │        │                │  smf-1-010203  smf-1-543210          │
                        └────────┼────────────────┼──────────────────────────────────────┘
                                 │                │
                     gateway-to-gateway       every gateway
                     (SBI proxy, cleartext)   registers here
                                 │                │
            ┌────────────────────┼────────────────┴────────────────────┐
            │                    │                                     │
┌───────── edge1 cloud ─────────┐│                     ┌───────── edge2 cloud ─────────┐
│ gateway (LB:7777)             ││                     │ gateway (LB:7777)             │
│ pran (LB:38412/SCTP)          │◀┘                    │ pran (LB:38412/SCTP)          │
│ damf  amf-10-100  amf-10-101  │                      │ damf  amf-10-100  amf-10-101  │
│ smf-1-010203  smf-1-543210    │                      │ smf-1-010203  smf-1-543210    │
└───────────────────────────────┘                      └───────────────────────────────┘
      ▲                                                      ▲
  UPF(edge1) / gNB(edge1)                                UPF(edge2) / gNB(edge2)
  tran-edge1                                             tran-edge2
```

**You are done when** the controller reports **3 gateways and 25 endpoints** — 10
pods in central, 6 in each edge, and the 3 UPFs:

```bash
curl http://ctrl.volantis.lab:8888/mon/endpoints
```

Start with [`../single-cloud/`](../single-cloud/README.md) if you have not: this
document is a delta against it, and §10 is the whole of the difference.

## Prerequisites

| | |
|---|---|
| six machines on one LAN | three running a cluster each, three running a UPF each. Fewer works if a UPF shares its cloud's machine — §1.1 |
| each cluster | Kubernetes with `kubectl` v1.21+, a `LoadBalancer` provider, and `nf_conntrack_proto_sctp` on the host if you forward SCTP |
| central's cluster | a default StorageClass, for the UDR's PersistentVolumeClaim |
| each UPF host | `gtp5g` ≥ 0.8.1 and < 0.9.20, `iptables`, root, and a route to its own cloud's gateway address |
| UERANSIM | on each user-plane host that simulates a gNB and UEs. Verified on v3.3.0 |
| binaries | `bin/upf` on each UPF host, `bin/uegen` wherever you provision from |
| the repository | on every machine you deploy from — `dns-hosts` is read at apply time and all three must apply the same one |

> Note: there is no TLS anywhere in this deployment and no SEPP. Every hop,
> including the ones that cross between clouds over whatever link you have, is
> cleartext HTTP. Run it on a private link or a VPN — §7.

## Quick start

**The setting.** Three clusters on three machines on one LAN, and one more
machine per cloud running that cloud's UPF — plus its gNB and UEs, if you are
simulating them. One cluster per machine, so each machine publishes the same
ports: `7777` for its gateway, `38412` for its PRAN, and on the central machine
`8888` for the controller as well.

Run each cluster step from the repository root, on the machine running that
cluster.

```bash
# 1. name the three machines: four names, three LAN addresses. This is the only
#    file in the deployment you edit — the manifests carry names, not addresses
$EDITOR deploy/k8s/manifest/multi-cloud/dns-hosts

# 2. deploy — from one machine holding all three kube contexts...
./deploy/k8s/k8s-deploy.sh -d multi -c central=<ctx>,edge1=<ctx>,edge2=<ctx>
#   ...or once on each machine, naming only its own cloud
./deploy/k8s/k8s-deploy.sh -d multi -c edge1

# 3. publish that cluster on its machine's LAN address. minikube and kind only:
#    a load balancer that hands out routable addresses needs none of it (§1.1)
minikube tunnel &
GW=$(kubectl -n volantis get svc gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp --dport 7777 -j DNAT --to-destination $GW:7777
#   the same again for pran-svc on 38412/SCTP, and on the central machine for
#   ctrl-svc on 8888

# 4. give the names to the three UPF hosts too
./deploy/k8s/k8s-deploy.sh -d multi --print-hosts | sudo tee -a /etc/hosts

# 5. subscribers — once for the whole deployment, not once per cloud
kubectl --context <central> port-forward -n volantis deployment/udr-dep 27017:27017 &
./deploy/deploy-external.sh subscribers --ues 6

# 6. on each cloud's user-plane host, with that cloud's own names
sudo ./deploy/deploy-external.sh upf \
    --gateway gw-central.volantis.lab --tran tran-central --cloud central
./deploy/deploy-external.sh gnb --pran <that machine's LAN address>
```

A gateway that registers and *stays* registered is the proof that machine's step
3 is right; one that appears and vanishes every few minutes is that machine's
rule, not the mesh.

> Note: fill in `dns-hosts` before deploying anything — with one cluster per
> machine those addresses are the machines' own, and you already know them.
> Nothing breaks while the file is still empty: the gateways retry until the
> names resolve.

---

## 1. Deploy

Once through, in this order:

1. **Decide the four addresses** — §1.1. One cluster per machine means they are
   the three machines' LAN addresses, and you know them before you deploy.
2. **Fill `dns-hosts`** with them — §1.2. It is the only file you edit.
3. **Apply all three clusters** — §1.3.
4. **Publish each cluster on its machine** — §1.1's `iptables` rules, which need
   the Services to exist and so come after step 3.
5. **Check the mesh formed** — §1.4.

Step 4 is the only one with no counterpart in the single-cloud deployment, and it
is there because on minikube or kind nothing a cluster publishes leaves the
machine running it.

### 1.1 The three machines, and what each publishes

Six machines: three run the clusters, and three run a UPF each, one per cloud
(§5) — with that cloud's gNB and UEs alongside, if you are simulating them. The
three user-plane hosts dial out and publish nothing to the mesh. The three
running clusters publish this:

| machine | cluster | LAN port → Service | dialled by |
| --- | --- | --- | --- |
| A | central | `8888` → `ctrl-svc` | the two edge gateways |
| A | central | `7777` → `gateway-svc` | peer gateways, its own UPF |
| A | central | `38412/SCTP` → `pran-svc` | its own gNBs |
| B | edge1 | `7777`, `38412/SCTP` | as above; no controller |
| C | edge2 | `7777`, `38412/SCTP` | as above; no controller |

One cluster per machine, so **the same ports mean the same thing on all three** —
no port arithmetic, and no manifest to edit: every `advertise.external` already
says `gw-<cloud>.volantis.lab:7777`, and §1.2 is what makes that true.

`38412` is not a mesh port and is not in `dns-hosts`: a gNB is configured with an
address, not a name, and it is the only thing that dials it. It is here because a
cluster that does not publish it has PRAN pods no gNB can reach.

**If your clusters publish routable addresses already** — a cloud provider's load
balancer, MetalLB on nodes that hold LAN leases, `--driver=none` — there is
nothing to do here. Read the addresses out and go to §1.2:

```bash
kubectl --context <central> -n volantis get svc ctrl-svc gateway-svc pran-svc
kubectl --context <edge1>   -n volantis get svc gateway-svc pran-svc
kubectl --context <edge2>   -n volantis get svc gateway-svc pran-svc
```

The rest of this subsection is for minikube and kind, where what those commands
report reaches the machine running that cluster and nowhere else.

**Forward the LAN ports into the cluster, on each machine.** Run this after
§1.3's apply — it reads addresses the Services have to exist for:

```bash
# on machine A, the central cluster
sudo modprobe nf_conntrack_proto_sctp   # or the SCTP rule silently does nothing
minikube tunnel &     # what makes an EXTERNAL-IP mean anything on this host

GW=$(kubectl   -n volantis get svc gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
CTRL=$(kubectl -n volantis get svc ctrl-svc    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PRAN=$(kubectl -n volantis get svc pran-svc    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp  --dport 7777  -j DNAT --to-destination $GW:7777
sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp  --dport 8888  -j DNAT --to-destination $CTRL:8888
sudo iptables -t nat -A PREROUTING -i <lan-if> -p sctp --dport 38412 -j DNAT --to-destination $PRAN:38412
```

Machines B and C take the same two rules minus `8888`: there is one controller
and it is in central.

**Without a tunnel to keep alive.** A `LoadBalancer` allocates a node port too,
and that answers with no tunnel process running at all:

```bash
GW_NP=$(kubectl -n volantis get svc gateway-svc -o jsonpath='{.spec.ports[0].nodePort}')
sudo iptables -t nat -A PREROUTING -i <lan-if> -p tcp --dport 7777 \
     -j DNAT --to-destination $(minikube ip):$GW_NP
```

**A UPF or gNB sharing a machine with a cluster** dials that machine's own LAN
address, and `PREROUTING` does not run for locally generated packets:

```bash
sudo iptables -t nat -A OUTPUT -d <this machine's LAN address> -p tcp --dport 7777 \
     -j DNAT --to-destination $GW:7777
```

Give the user plane a machine of its own — which §5 assumes — and this does not
arise.

> Note: pin whatever the rule points at. A `LoadBalancer`'s `EXTERNAL-IP` *is* its
> ClusterIP, and a delete-and-re-apply allocates a new one — leaving an `iptables`
> rule aimed at an address nothing answers on, with no error to say so. Set
> `spec.clusterIP` on the two Services, or `spec.ports[].nodePort` for the
> node-port form. §10 is why the published addresses stop at the machine.

**How you know it worked.** The controller refuses to admit a gateway it cannot
reach at an advertised address, and evicts one that stops answering. So a gateway
that registers and *stays* registered is the proof that machine's rule is right,
and §1.4's `/mon/endpoints` is where you see it: a cloud whose gateway never
registered contributes no endpoints at all.

### 1.2 The four cross-cloud addresses

**One file to fill in — `dns-hosts`.** Four names, three addresses:

```
# deploy/k8s/manifest/multi-cloud/dns-hosts
192.168.1.10     ctrl.volantis.lab
192.168.1.10     gw-central.volantis.lab
192.168.1.11     gw-edge1.volantis.lab
192.168.1.12     gw-edge2.volantis.lab
```

Never edit the names themselves. They appear literally in `central/gateway.yaml`,
`edge1/gateway.yaml`, `edge2/gateway.yaml` and each UPF's `--gateway`, and this is
who dials which:

| name | what it is | who dials it |
| --- | --- | --- |
| `ctrl.volantis.lab:8888` | the central `ctrl-svc` LoadBalancer | both edge gateways, and you |
| `gw-central.volantis.lab:7777` | the central `gateway-svc` | the controller's probe, peer gateways, UPF(central) |
| `gw-edge1.volantis.lab:7777` | edge1's `gateway-svc` | same, for edge1 |
| `gw-edge2.volantis.lab:7777` | edge2's `gateway-svc` | same, for edge2 |

`k8s-deploy.sh` turns that into `hostAliases` on exactly the pods that dial across
a cluster boundary — `ctrl-dep` and every `gateway-dep` — and prints it for the
three UPF hosts:

```bash
./deploy/k8s/k8s-deploy.sh -d multi --print-hosts | sudo tee -a /etc/hosts
```

Nothing else needs the names: an NF pod reaches its own gateway through cluster
DNS (`gateway-svc.volantis.svc.cluster.local`) and never learns a remote address
at all. With real DNS serving these names, leave `dns-hosts` empty and pass
`--no-hosts`.

To change an address, edit `dns-hosts` and re-apply — no ConfigMap edit, no
`kubectl rollout restart`.

> Note: there are no other placeholders. Nothing in `central/`, `edge1/` or
> `edge2/` carries an address to substitute — a pod does not know its own, and the
> UPF takes its own as arguments, deriving its address from the route to its
> gateway.

### 1.3 Apply

```bash
# from the repository root — all three clusters, one command
./deploy/k8s/k8s-deploy.sh -d multi -c central=<ctx>,edge1=<ctx>,edge2=<ctx> -t v0.2.0

./deploy/k8s/k8s-deploy.sh -d multi -c edge1 -n -t v0.2.0   # one cloud, dry run
```

One command needs one kubeconfig holding all three contexts, which three machines
each running their own minikube do not have. Either merge them onto whichever
machine you deploy from, or deploy from each machine in turn, naming only its own
cloud and leaving the context alone:

```bash
./deploy/k8s/k8s-deploy.sh -d multi -c central   # on machine A, current context
./deploy/k8s/k8s-deploy.sh -d multi -c edge1     # on machine B
./deploy/k8s/k8s-deploy.sh -d multi -c edge2     # on machine C
```

Use the script rather than `kubectl apply -k` on a cloud's directory: applied on
its own it names `volantis-<nf>` with no registry, which nothing can pull.
`kubectl kustomize central/` renders a cloud's base if you want to read it first —
**`-k`, not `-f`**, since each directory carries a `kustomization.yaml`.

All three clusters pull from one place: `ghcr.io/reogac/volantis-<nf>:<tag>`, tag
`v0.1.1` by default. The packages are public, so no cluster needs a registry
account, and `IMAGE` at the top of `k8s-deploy.sh` is the only place the prefix is
written.

Or install them as Helm releases, one per cluster —
[`../../helm/`](../../helm/README.md) covers what differs, and why the script is
worth using even so: it is what turns `dns-hosts` into the `hostAliases` these
pods need to address each other by name.

```bash
./deploy/k8s/k8s-deploy.sh --engine helm -d multi -c central=<ctx>,edge1=<ctx>,edge2=<ctx>
```

**Order does not matter.** Every component retries its way into the mesh instead
of requiring what it depends on to already exist: a gateway whose controller is
in a cloud that is not up yet retries forever; an NF started before its own
cloud's gateway waits for it; an edge NF's configuration pull is a two-hop
cross-cloud call, so it simply retries until the link and both gateways are up.
Until its pull succeeds an instance is registered but **not selectable**.

Then start the three UPFs, one per cloud, from the repository root on each
cloud's user-plane host (§5):

```bash
sudo ./deploy/deploy-external.sh upf \
    --gateway gw-central.volantis.lab --tran tran-central --cloud central
# ...and the edge1 / edge2 hosts, with their own names
```

> Note: each UPF's config carries `"firewall": {"manage": true}`, so it installs
> its own host rules — three hosts, and no `iptables` to run by hand on any of
> them. What is per-host is `--n6-dev`, because the interface UE traffic leaves by
> need not be the same on three machines.

### 1.4 Check it came up

```bash
curl http://ctrl.volantis.lab:8888/mon/services
curl http://ctrl.volantis.lab:8888/mon/endpoints
```

Read `/mon/endpoints`: each endpoint carries the `_gw-cloud` label its gateway
stamped on it, so this is where you see whether edge1's AMF actually landed in the
`edge1` group.

Expect 3 gateways and 25 endpoints: 10 pods in central (NSM, UDM, AUSF, PCF, PRAN,
DAMF, two AMFs, two SMFs), 6 in each edge (PRAN, DAMF, two AMFs, two SMFs), and the
3 UPFs. The controller, the gateways and the UDR are not endpoints — they are not
mesh NFs.

### 1.5 What must be reachable from what

| from | to | why |
| --- | --- | --- |
| each edge gateway pod | `ctrl.volantis.lab:8888` | registration, definitions, endpoint replay |
| each gateway pod | the other two `gw-*.volantis.lab:7777` | cross-cloud SBI proxying, both directions |
| each UPF host | its own cloud's `gw-*.volantis.lab:7777` | registration, and all of its SBI in and out |
| each gNB | its cloud's machine on `38412/SCTP` | NGAP to `pran-svc` |
| each gNB | its cloud's UPF host on `2152` | GTP-U. This one never touches the mesh |

The first three are names, so each side must also *resolve* them — §1.2. A name
that resolves nowhere and a port that is firewalled fail the same way: the gateway
retries forever and logs it.

Pod-to-pod reachability *between* clusters is deliberately not on this list. It is
not needed and is not assumed.

---

## 2. Transport networks and UPF selection

"The core picks the UPF next to the gNB the session came from" rests entirely on
this section, and it is not the mesh doing it.

Each cloud has one transport network, named in three places that must agree:

| | central | edge1 | edge2 |
| --- | --- | --- | --- |
| `central/nsm.yaml` → `transportNetworks` | `tran-central` | `tran-edge1` | `tran-edge2` |
| each cloud's `pran.yaml` → `transportNetworks` | `tran-central` | `tran-edge1` | `tran-edge2` |
| the UPF's `--tran` | `tran-central` | `tran-edge1` | `tran-edge2` |

The chain is:

1. PRAN reports its `transportNetworks` with the UE's context; the AMF passes them
   to the SMF as the session's RAN transport networks.
2. The SMF builds a topology of every UPF that serves its slice and whose
   interfaces are on transport networks NSM told it about.
3. It runs Dijkstra from an interface on one of the RAN's transport networks. A
   UPF with no face on `tran-edge1` is simply not a starting node for a session
   from edge1's gNB.

So a session from the edge1 gNB lands on the edge1 UPF because that is the only
UPF with an interface named `tran-edge1` — regardless of which cloud's SMF serves
it, and regardless of anything in the service definitions.

> Note: transport network names are exact strings. A typo does not fail loudly; it
> produces "no UPF found" at session establishment, because the mismatched name is
> filtered out in step 2.

**Each UPF here has exactly one interface, so there are no N9 links.** The topology
is three disconnected single-node graphs. That is what you want for "the local UPF
serves the local gNB", and it means an inter-cloud handover has no data path to
build. If you need one, give the UPFs a second `n9` interface entry on a shared
transport network (say `tran-core`) reachable from all three, add it to
`nsm.yaml`, and Dijkstra will find the two-hop path.

---

## 3. Change configuration, and load subscribers

**NSM's own configuration is immutable for the life of its process.** To edit
`central/nsm.yaml`:

```bash
kubectl --context <central> apply -f central/nsm.yaml
kubectl --context <central> rollout restart deployment/nsm-dep -n volantis
```

Every NF kind that reads from NSM re-pulls periodically and picks the change up on
its own. What they *claim* — an AMF pointer, a UE IP segment — is a separate
operation and is not repeated once held, because repeating it could hand a running
instance a different one. A refresh never replaces a good configuration with an
insufficient one: a pull that comes back short is refused rather than applied.

**Service definitions are live.** Edit `central/service-definitions.yaml`, apply
it, and the controller's watch picks it up within seconds; every agent takes it on
its next configuration poll, so a change is in force everywhere inside a minute
with no restart anywhere. A 60 s reconcile sits behind the watch as the
correctness layer.

> Note: changing a definition's `spec.selector` is not an edit — it is a
> *different service*, so the old identity is deleted and the new one subscribed.

**Load the subscribers once for the whole deployment**, not once per cloud. The
UDR is ClusterIP-only in the central cluster, and `uegen` runs outside it:

```bash
kubectl --context <central> port-forward -n volantis deployment/udr-dep 27017:27017 &

./deploy/deploy-external.sh subscribers --ues 6
```

Which cloud a UE lands in is decided by the gNB it attaches to, not by its
subscription, so one batch serves all three.

> Note: the SUCI **public** keys the subscribers are provisioned against must be
> the halves of the private keys in `central/nsm.yaml`. They disagree quietly —
> authentication fails with a de-concealment error on the first UE.

---

## 4. Locality: keeping a request in its cloud

Without this, an edge1 DAMF picks an AMF uniformly at random from all three clouds
and two thirds of its traffic crosses the link. Five definitions —
`damf-001-01`, both `amf-001-01-<set>` and both `smf-001-01-<slice>` — carry an
annotation that fixes that:

```json
{
  "stateful": true,
  "groups": {
    "central": {"selectors": {"_gw-cloud": "central"}},
    "edge1":   {"selectors": {"_gw-cloud": "edge1"}},
    "edge2":   {"selectors": {"_gw-cloud": "edge2"}}
  },
  "routes": [
    {"from": {"cloud": "central"}, "fallthrough": true,
     "destinations": [{"group": "central", "weight": 100}]},
    {"from": {"cloud": "edge1"},   "fallthrough": true,
     "destinations": [{"group": "edge1",   "weight": 100}]},
    {"from": {"cloud": "edge2"},   "fallthrough": true,
     "destinations": [{"group": "edge2",   "weight": 100}]}
  ]
}
```

`fallthrough: true` is what makes each route a *preference*. Drop it and the route
becomes binding: a cloud whose local producer is gone stops serving that service
instead of reaching across. Both are legitimate — binding is how you express "this
slice never leaves this cloud" — but prefer-and-spill is what is configured here.
There is no catch-all route because the service-wide balancer already is one, so N
clouds cost N routes.

### 4.1 The two sides match different label sets

This is the one thing to get right, and it is why the same fact is written twice
under two different keys.

| | key | where you set it | what it is compared against |
| --- | --- | --- | --- |
| **producer side** — `groups[].selectors` | `_gw-cloud` | `labels` in each cloud's `gateway.yaml`, once | the endpoint's labels, which the controller builds by merging the gateway's own labels (prefixed `_gw-`) into what the pod reported |
| **consumer side** — `routes[].from` | `cloud` | `mesh.labels.cloud` in every NF's ConfigMap | the agent's *own* labels: its configured `mesh.labels` plus the locality the mesh assigned it |

In Kubernetes an NF's `mesh.labels` are **discarded** for its endpoint — the
gateway takes pod labels from the API server instead. They are still the only
thing a route's `from` is matched against, because the agent never sees its own pod
labels. So `mesh.labels.cloud` does nothing on the producer side and everything on
the consumer side, and `_gw-cloud` is the reverse. Neither substitutes for the
other.

> Note: getting one wrong fails **quietly**. A group that selects nothing makes the
> route fall through; a `from` that matches nothing makes the route never apply.
> Either way the service still works — just not locally. `/mon/services` and
> `/mon/endpoints` are where you see which is which.

### 4.2 What is deliberately not locality-routed

- `amf-001-01` and `smf-001-01`, the set-less and slice-less umbrellas. They exist
  for subscription, not for selection.
- `upf-001-01`. The SMF does not select a UPF through routing at all (§2).
- `nsm`, `udm`, `ausf`, `pcf`, `udr` — one instance, in one cloud. Nothing to
  choose between.

---

## 5. The three UPF hosts

> **[`../../../external/README.md`](../../../external/README.md)** is what runs the
> UPF, the gNBs and the UEs — how to run them, what they need of a host, and the
> several things that go wrong quietly. Here you do it three times, once per cloud.
> **[`../single-cloud/README.md` §3.1](../single-cloud/README.md#31-what-has-to-agree-with-the-cluster)**
> is the list of values a cloud's manifests and its host processes have to agree
> on; each cloud needs its own copy of that agreement.

One host per cloud, each carrying that cloud's UPF and, if you are simulating the
radio, its gNB and UEs alongside:

| | central | edge1 | edge2 |
| --- | --- | --- | --- |
| `--gateway` | `gw-central.volantis.lab` | `gw-edge1.volantis.lab` | `gw-edge2.volantis.lab` |
| `--tran` | `tran-central` | `tran-edge1` | `tran-edge2` |
| `--cloud` | `central` | `edge1` | `edge2` |
| `--pran`, for the gNB | machine A's LAN address | machine B's | machine C's |

**The UPF is the only network function outside a cluster**, for the reason it
always is: its data path needs the `gtp5g` kernel module on the host. Everything
else, PRAN included, is a pod.

For the UPF, `mesh.labels` **is** what the endpoint carries — there is no pod for
the gateway to read. So `cloud` there does double duty: it is both the
consumer-side label a route's `from` matches and part of the endpoint's own label
set. For every pod in the deployment those are two different places (§4.1), and
the UPF is the exception that makes the distinction visible.

> Note: `mesh.registered.address` is likewise the UPF's own, derived from the route
> toward its gateway. On a multi-homed host that lookup can pick the wrong
> interface, and the address it picks is what every peer will dial — `--upf-ip`
> overrides it.

### 5.1 The gNBs, and where they point

A gNB dials two addresses, and neither is a mesh address:

| what | where | why |
| --- | --- | --- |
| NGAP/SCTP | its cloud's machine on `38412` — `pran-svc` (§1.1) | the N2 association |
| GTP-U | its cloud's UPF host on `2152` | user-plane, never through the mesh |

`--pran` is the first of those. On a cluster whose load balancer publishes a
routable address, use that address; on minikube or kind, the machine's own, which
is what §1.1's SCTP rule forwards.

Which cloud a gNB belongs to is decided by which PRAN it dials. That PRAN's pod
labels put it in the `pran-001-01-00N` definition, and its `mesh.labels.cloud` is
what the locality routes match on when it picks a DAMF (§4). Point a gNB at another
cloud's machine and the UE is served entirely by that cloud; nothing objects, and
nothing corrects it.

---

## 6. Scale AMF and SMF

The mechanism is identical to the single-cloud deployment, and
[`../single-cloud/README.md` §5](../single-cloud/README.md#5-scale-amf-and-smf) is
the full treatment: what the unit is, the ceilings, adding a set or a slice,
draining, and an example HPA driven by `/state`. What follows is only what three
clouds change.

### 6.1 The ceilings are global, not per cloud

| resource | ceiling | scope |
| --- | --- | --- |
| AMF pointers | 64 per AMF set | the **whole set, across all three clouds** — NSM allocates from one range |
| UE IP segments | how many an address space holds — `segmentLength: 22` over a /16 is 64 | **all SMF instances everywhere**, one segment each per address space |

So "one AMF of set 10-100 per cloud" spends 3 of that set's 64 pointers, and the
six SMF pods spend 6 of the 64 segments. Both are reclaimed when the endpoint
leaves — but not instantly: liveness is 30 s × 3, so a departure takes up to ~90 s
to be noticed, and a scale-down-then-up faster than that can find the resource
still held.

### 6.2 Scale out, per cloud

```bash
kubectl --context <edge1> scale deployment/amf-10-100-dep -n volantis --replicas=3
kubectl --context <edge1> scale deployment/smf-1-010203-dep -n volantis --replicas=2
```

New replicas register with edge1's gateway, so they are stamped `_gw-cloud: edge1`
and join the `edge1` group of their definition on their own. No definition edit is
needed to scale within a cloud — that is the point of selecting a group by gateway
label rather than by naming instances.

> Note: an AMF replica is not selectable until NSM has given it a pointer, and an
> SMF replica not until it has a pool. Watch `/ready` on port 7001, or the
> `mesh_sbi_active` gauge.

### 6.3 Scale out to a *new* cloud

Adding cloud `edge3` is: a gateway with `id: edge3` and `labels: {cloud: edge3}`,
`edge3` added to the controller's `gateways` allow-list, a fourth transport network
in `nsm.yaml` (and a PRAN and UPF using it), and — for each of the five
locality-routed definitions — one more group and one more route. The AMF and SMF
Deployments are copies with `mesh.labels.cloud: edge3`.

`edge3/` needs its own `kustomization.yaml` listing those files, and `edge3` added
to the `central|edge1|edge2` case in `k8s-deploy.sh`, before either can deploy it.

> Note: the controller's allow-list is the one that fails obscurely if you forget
> it. The gateway retries forever and logs a refusal, and nothing in `edge3` ever
> becomes discoverable.

### 6.4 Drain a cloud — the trap

`"drain": true` on a group removes it from every route destination that targets it,
while leaving its endpoints in the service, so existing stateful pins keep working
and no *route* sends new selections there. With the routes as written that is **not
enough**: they are `fallthrough: true`, so a request that finds its group drained
falls through to the service-wide balancer — which holds every endpoint of the
service, drained ones included.

To actually stop new sessions landing in edge1, drain its group *and* add a binding
catch-all that names only the survivors:

```json
"groups": {
  "central": {"selectors": {"_gw-cloud": "central"}},
  "edge1":   {"selectors": {"_gw-cloud": "edge1"}, "drain": true},
  "edge2":   {"selectors": {"_gw-cloud": "edge2"}}
},
"routes": [
  {"from": {"cloud": "central"}, "fallthrough": true,
   "destinations": [{"group": "central", "weight": 100}]},
  {"from": {"cloud": "edge1"},   "fallthrough": true,
   "destinations": [{"group": "edge1",   "weight": 100}]},
  {"from": {"cloud": "edge2"},   "fallthrough": true,
   "destinations": [{"group": "edge2",   "weight": 100}]},
  {"destinations": [{"group": "central", "weight": 100},
                    {"group": "edge2",   "weight": 100}]}
]
```

The last route has no `match` and no `from`, so it matches everything that got that
far, and it is binding — nothing reaches the service-wide balancer any more. Apply,
wait for the sessions pinned to edge1 to drain, then scale its Deployments to 0 and
remove the extra route.

Without that last route, `drain` on a prefer-local deployment is close to a no-op.
That is not a bug: a drained group is out of *route* selection, and the
service-wide fallback was never part of a route.

---

## 7. Controller HA, and what is not HA

**The controller is replicated**, two replicas in the central cloud. Exactly one
serves: leadership is a Kubernetes `Lease` named `volantis-controller` with a 15 s
duration, `/ready` answers 200 only for the leader so the Service keeps the standby
out, and the standby refuses control traffic that reaches it in the window before
kube-proxy notices.

A new leader **starts empty**. There is no shared state and nothing is persisted;
the three gateways replay their endpoints into it, and it re-reads the definitions
from the namespace's Service objects. Recovery is bounded by the lease duration
plus one replay round, and during it nothing on the *signaling* path is affected —
the controller is never on the request path. What is affected: no gateway can
register, no NF can join, and a definition change does not propagate.

`tolerations` on the Deployment cut the unreachable-node eviction from 300 s to
30 s. Without them Kubernetes would hold the pod on a dead node for five minutes,
long past the lease.

**The gateways are not replicated**, at `replicas: 1`, because gateway HA is not
implemented. Each gateway is a single failure domain for all of its cloud's
cross-cloud signaling and for everything its UPF does. Losing edge1's gateway does
not affect central or edge2 among themselves.

**There is no TLS.** Not between agent and gateway, not gateway to gateway, not to
the controller. In this topology that includes the links *between clouds*, which in
a real deployment cross something you do not own. Every process takes
`--cert/--key/--pem` — give all three or none — but issuing and distributing the
certificates is not part of these manifests. Until it is, run this on a private
link or a VPN, and do not put the LoadBalancer addresses on the public internet.

**There is no SEPP** and no `plmnPeers` in `nsm.yaml`: one PLMN, no roaming.

**There is no shared state store.** A stateful NF keeps per-UE and per-session
context in its own process, and the mesh's job is to keep signaling arriving at the
same instance. Scaling *in* drops the contexts on the instance that goes away, and
an instance failure is unrecoverable for its UEs. Known limitations, not bugs.

---

## 8. When something does not work

**A gateway never appears in `/mon/endpoints`.** Its `id` is not in the
controller's `gateways` allow-list, or `ctrl.volantis.lab` does not resolve from
that pod (`dns-hosts`, §1.2), or the edge cluster cannot reach it. The gateway logs
the refusal and retries forever, so the pod looks healthy — read its log, not its
status.

**Everything registers but cross-cloud calls fail.** Some gateway is missing
`advertise.external`, or has one its peers cannot route to. That address is the
only one a peer gateway is given; `local` is for the controller and the controller
only.

**A gateway registers, then vanishes a few minutes later, over and over.** The
controller reached it once at an advertised address and then stopped: admission
probes that address, and liveness keeps checking that same one until tolerance runs
out. On a host-local cluster this is the machine's own exposure — an `EXTERNAL-IP`
reallocated by a delete-and-re-apply, or a `minikube tunnel` that died and left its
route behind. §1.1.

**An NF is Running but never Ready.** It has not completed its NSM pull. For an
edge NF that pull crosses two gateways, so check in order: is edge's gateway
registered, is central's gateway registered, is NSM itself ready. `/state` on port
7001 answers `503 {"active": false}` for exactly this.

**A request goes to the wrong cloud.** Read `/mon/endpoints` and check the
`_gw-cloud` label on the producer, then check `mesh.labels.cloud` in the
*consumer's* ConfigMap. §4.1 — the two sides use different keys and a mismatch is
silent.

**A route matched and the request was refused** (`ReasonNoProducer`). A binding
route with no producer refuses rather than serving from outside itself. The
controller logs it with the route's `match`/`from`. If you meant a preference, you
wanted `"fallthrough": true`.

**"No UPF found" at session establishment.** A transport network name disagrees
between `nsm.yaml`, each cloud's `pran.yaml` and each UPF's `--tran`. §2 — they are
exact strings and a mismatch is filtered silently.

**A UE attaches but gets no IP.** The SMF for that slice holds no segment for the
address space the session needs. Either the space is exhausted across all clouds,
or that SMF has not finished its pull — it is not selectable in the second case, so
look for the first. The SMF logs the space by name at error level when NSM grants
it nothing, and asks again on every refresh.

**An NF that died is still being selected.** Liveness is 30 s × tolerance 3, so a
dead endpoint stays in every subscriber's balancer for up to ~90 s, and there is no
request-path retry. Every request steered at it in that window is a hard procedure
failure. Known, and the reason the `/ready` probes matter.

### Where to look

```bash
# controller, from outside
curl http://ctrl.volantis.lab:8888/mon/services
curl http://ctrl.volantis.lab:8888/mon/endpoints

# any gateway, from inside its cluster
kubectl exec -n volantis deployment/gateway-dep -- wget -qO- localhost:7777/mon/endpoints

# any NF's agent server
kubectl port-forward -n volantis deployment/amf-10-100-dep 7001:7001
curl localhost:7001/ready ; curl localhost:7001/state ; curl localhost:7001/metrics
```

---

## 9. What is in here

| path | contents |
| --- | --- |
| `central/` | everything in the central cluster: controller (HA), gateway, UDR, NSM, UDM, AUSF, PCF, PRAN, DAMF, two AMFs, two SMFs, **and the service definitions for all three clouds** |
| `edge1/`, `edge2/` | namespace, gateway, PRAN, DAMF, two AMFs, two SMFs. No definitions — see §10 |
| `dns-hosts` | where the controller's and the three gateways' names resolve (§1.2) |

Per cluster the files are:

| file | what it declares |
| --- | --- |
| `namespace.yaml` | the `volantis` namespace |
| `controller.yaml` | *central only* — ServiceAccount, RBAC (Services + Leases), config, 2-replica Deployment, LoadBalancer |
| `gateway.yaml` | ServiceAccount, RBAC (pods), config, Deployment, LoadBalancer |
| `udr.yaml` | *central only* — MongoDB, PV/PVC, ClusterIP |
| `nsm.yaml` | *central only* — the system-wide configuration |
| `udm.yaml`, `ausf.yaml`, `pcf.yaml` | *central only* |
| `pran.yaml` | Proxy-RAN, one per cloud, behind an SCTP LoadBalancer on 38412 |
| `damf.yaml` | the default AMF, one per cloud |
| `amf-10-100.yaml`, `amf-10-101.yaml` | one instance of each set, per cloud |
| `smf-1-010203.yaml`, `smf-1-543210.yaml` | one instance of each slice, per cloud |
| `service-definitions.yaml` | *central only* — 16 headless Services, the whole catalogue |
| `kustomization.yaml` | what a cloud's apply applies — a new Deployment must be added to its `resources:` list |

The deployment as written: 2 AMF sets (`10-100` serving both slices, `10-101`
serving `1-543210` only), 2 slices, 1 data network (`internet`, 10.60.0.0/16), 3
transport networks (`tran-central`, `tran-edge1`, `tran-edge2`), PLMN 001-01, AMF
region 10.

---

## 10. Why it is like this

Skip until you need it.

**This is the single-cloud deployment, three times over, with two addresses made
external.** Each cloud is the same set of manifests: a gateway, a PRAN behind an
SCTP LoadBalancer, a DAMF, the AMFs and the SMFs, and a UPF on a host beside it.
What multi-cloud adds is that the controller and every gateway must now be
reachable *from outside their own cluster* — the controller because two of the
three gateways register across a cluster boundary, and each gateway because the
other two proxy SBI to it — and that a gateway must **advertise** that external
address, since it is the only one a peer is ever given.

Five things follow, and they are the only ones that are new:

- **One controller, in the central cloud, and it is the only definition store.** It
  reads service definitions from the Service objects in *its own* namespace in *its
  own* cluster. So `central/service-definitions.yaml` declares the catalogue for all
  three clouds, and the edge clusters declare nothing. An edge NF's membership still
  works because membership is decided from the labels its gateway reports to the
  controller — the definition and the producer never had to be in the same cluster.
- **Every gateway needs `advertise.external`.** In single-cloud it could be omitted;
  here omitting it makes that cloud's endpoints unreachable from the other two.
- **Cross-cloud SBI is proxied, twice.** Consumer → its own gateway → the producing
  cloud's gateway → producer. The request carries `epId`/`gwId` headers, not an
  address, and no NF ever learns a remote endpoint's address. That is what makes
  three separate pod networks work at all, and why each gateway is on the critical
  path for its cloud.
- **The UPF talks to its cloud's pods through the gateway too.** The gateway labels
  pods `_net: cluster` and plain host processes `_net: host`, so only equal
  localities get the direct path. The one thing a UPF host must reach is therefore
  its gateway's LoadBalancer address, not the pod network. If host-to-pod routing
  *does* exist in your setup and you want the direct path, add `"_net": "cluster"`
  to [`../../../external/config/upf.json`](../../../external/config/upf.json).
- **Locality routing.** Five definitions carry routes that mean "prefer a producer
  in the consumer's own cloud, spill to another when there is none" — §4.

**DAMF is deployed per cloud**, and that is a choice rather than a consequence. It
is the first NF a UE's initial NAS reaches, one hop from PRAN, and PRAN is per
cloud — putting DAMF centrally would send every initial registration across the
inter-cloud link before the UE has an AMF at all. For the simpler placement, delete
`edge1/damf.yaml` and `edge2/damf.yaml`; nothing else changes, and the locality
routes on `damf-001-01` degrade to "everyone uses the central one" on their own.

**Why a cluster's published addresses stop at its machine.** Two host-local layers
are stacked, and fixing one does not help. The node's address is a bridge address —
with minikube's docker driver, `192.168.49.2` on a bridge whose host side is
`192.168.49.1`, a subnet that exists only in that machine's routing table. And the
`EXTERNAL-IP` is not an address anything routes to: `minikube tunnel` sets it to the
Service's own *ClusterIP*, out of `10.96.0.0/12`, and installs `10.96.0.0/12 via
<node>` on the host. That route is the only thing making the address mean anything.

`DNAT` in `PREROUTING` works because it rewrites the destination and then hands the
packet to the host's ordinary routing decision, which is where the tunnel's route
applies. Replies need no `SNAT`: the node's default route is the host, so the
host's conntrack sees them and undoes the translation.

The trade between the two forms is legibility against a live dependency. The tunnel
form reads better — the same port on both sides, matching what `advertise.external`
says — but the tunnel is a root process that has to stay up, and killing it
ungracefully leaves its route behind, so a crashed tunnel blackholes instead of
failing loudly. The node-port form depends on nothing but the node.

**No pod ever dials its own machine's LAN address**, so there is no hairpin to
arrange. Two things in the manifests make that true and are worth leaving alone.
`central/gateway.yaml` advertises a `local` address as well as an external one, and
the controller probes a gateway's advertised addresses local-first, adopting the
first that answers *as itself* — so it reaches the central gateway by ClusterIP and
never resolves `gw-central.volantis.lab`. In the other direction
`central/gateway.yaml` names the controller as
`ctrl-svc.volantis.svc.cluster.local:8888`; only the two edge gateways use
`ctrl.volantis.lab`.

**If you would rather not NAT at all**, put the node on the LAN — `--driver=none`,
or a VM with a *bridged* adapter so it takes a LAN lease. Node ports then land on a
real LAN address, MetalLB in L2 mode with a pool from that LAN works, and every
advertised address is genuinely the one everybody dials. Better shape, more
disruptive to set up. MetalLB is not an option on top of the docker driver: it would
answer ARP inside the bridge, where the LAN never hears it.
