# The components that run outside a cluster

Deploy the UPF, a UERANSIM gNB and UEs against any Volantis deployment, and
prove the data path end to end.

```
            this host                                the cluster
  ┌──────────────────────────────┐        ┌──────────────────────────────┐
  │  nr-ue      (netns ue1)      │        │                              │
  │    │ radio link              │        │   PRAN ─── DAMF ─── AMF      │
  │  nr-gnb ─────────────────────┼── N2 ──┼─► pran-svc          │        │
  │    │ N3 (GTP-U 2152)         │        │                    SMF       │
  │  UPF ◄───────────────────────┼── N4 ──┼── gateway-svc ──────┘        │
  │    │ N6                      │        │   NSM   UDM   PCF   UDR      │
  └────┼─────────────────────────┘        └──────────────────────────────┘
       ▼ the data network
```

**You are done when** a UE holds a PDU session and `upfgtp`'s counters climb in
both directions:

```
  ok     PDU session up on uesimtun0  10.60.0.1/32
  upfgtp: RX 24 pkts, TX 24 pkts, TX errors 2
```

**One copy, used by every deployment** — the two in
[`../k8s/manifest/`](../k8s/manifest/) and the single-machine one in
[`../local/`](../local/README.md). Only the addresses differ, and you pass them
as arguments. Run every command from the repository root.

## Prerequisites

Check them all by name before you start anything:

```bash
./deploy/deploy-external.sh check              # everything a plain user can test
sudo ./deploy/deploy-external.sh check upf     # gtp5g, iptables, GTP-U
```

| | |
|---|---|
| host | Linux, with `iproute2`, `iptables`, and `net.ipv4.ip_forward` writable |
| kernel module | `gtp5g` ≥ 0.8.1 and < 0.9.20, loaded — the UPF refuses anything outside that range. Verified on 0.8.3 |
| UERANSIM | `nr-gnb`, `nr-ue`, `nr-cli` on `PATH`, in `bin/`, or at `$UERANSIM`. Verified on v3.3.0 |
| binaries | `bin/upf` and `bin/uegen` from the release archive. `bin/gtp5g-tunnel` is optional, and the only way to read the kernel's own rule set |
| root | from the UPF onwards, and for every UE |
| kubectl | to read the two Service addresses and to port-forward the database. Verified on v1.24.3 |

Give three addresses once. They are saved in `deploy/run/external/settings`,
and every later command reads them back:

| flag | what it is | where to get it |
|---|---|---|
| `--pran` | where the gNB opens its NGAP/SCTP association | `kubectl -n volantis get svc pran-svc`, the `EXTERNAL-IP` |
| `--gateway` | where the UPF registers | `kubectl -n volantis get svc gateway-svc` |
| `--db` | the subscriber database | a `kubectl port-forward`; defaults to `mongodb://127.0.0.1:27017` |

> Note: on minikube, keep `minikube tunnel` running in its own terminal and
> **not** under `sudo`, or neither Service has an address. Add
> `--pod-cidr 10.244.0.0/16 --node-ip "$(minikube ip)"` so the UPF can reach NSM.

---

## 1. The UPF

The user plane. It terminates GTP-U from the gNB on N3, forwards UE traffic to
the data network on N6, and serves N4 to the SMF. It runs out here because its
data path needs the `gtp5g` kernel module on the host.

Start the **gNB first** (§2) — `upf start` moves the gNB's radio link. Then:

```bash
sudo ./deploy/deploy-external.sh upf --gateway <gateway-svc IP>
```

Override a default only where it does not fit:

| flag | default | change it when |
|---|---|---|
| `--upf-ip` | the route toward `--gateway` | the address the SMF must dial for N4 is another one |
| `--upf-bind` | every interface | something else on this host already holds 9001/7001 |
| `--tran` | `tran1` | multi-cloud: `tran-central`, `tran-edge1`, `tran-edge2` |
| `--n6-dev` | the default route's | UE traffic should leave by another interface |
| `--pod-cidr`, `--node-ip` | none | this host has no route to the pod network |

`start` checks the host, adds the pod route, creates `ue1`'s namespace, relinks
the gNB, renders `config/upf.json` into `run/external/generated/`, and waits for
`/ready`. Read the last two lines:

```
  ok     ready — it has pulled its data networks from NSM and opened its N4 gate
  ok     Anchored data networks: [10.60.0.0/16]
```

Inspect what reached the kernel — the device, the route and the chains:

```bash
sudo ./deploy/deploy-external.sh upf show
```

One `MASQUERADE` per anchored data network is right. `No chain` means the UPF
got no data network.

> Note: `Anchored data networks: []` means it will refuse every session. Fix it
> before going further — §7.1.

Stop it, which also removes the pod route:

```bash
sudo ./deploy/deploy-external.sh upf stop
```

## 2. The gNB

UERANSIM's simulated base station. It holds one SCTP association to Proxy-RAN
and knows no AMF address, which is what lets AMF instances come and go behind
it.

```bash
./deploy/deploy-external.sh gnb --pran <pran-svc IP>
```

No root. `--gnb-ip` defaults to the route toward `--pran`; `--tac` defaults to
`1`. Look for both lines:

```
  gnb    started (pid 31402), radio link 10.99.0.1, N2 to 10.111.12.117:38412
  ok     NG Setup succeeded — the gNB is attached to Proxy-RAN
```

N2 and N3 stay on `--gnb-ip`. The radio link moves onto `10.99.0.1` once `ue1`'s
veth exists, and `upf start` does that for you. Move it by hand only if you
started the gNB after the UPF:

```bash
./deploy/deploy-external.sh gnb relink     # a no-op when the address is right
```

> Note: attached, but no UE ever finds a cell? The gNB completes NG Setup even
> when its other sockets failed to bind — §7.2.

## 3. The UE

### 3.1 Provision the subscribers

`uegen` writes each subscriber into the UDR's MongoDB and the matching UE
profile to `run/external/ue/ue-<n>.yaml`, so the two cannot disagree.

Open a path to the database, then provision:

```bash
kubectl -n volantis port-forward svc/udr-mongo 27017:27017 &
./deploy/deploy-external.sh subscribers --db mongodb://127.0.0.1:27017
```

No root. `--ues <n>` sets the count, default 2. Re-run it freely — the same seed
provisions the same subscribers. `subscribers list` prints what is in the
database.

> Note: already running a MongoDB on 27017? Forward to another port instead, or
> every subscriber lands in the wrong database and nothing says so — §7.3.

### 3.2 The namespace

Each UE runs in its own network namespace, with its own /24 and resolver. You do
not create it: `upf start` makes `ue1`'s, `ue <n>` makes any other, `stop`
removes them.

```
ue1   10.99.0.2/24  <->  10.99.0.1     the gNB's radio link is on this one
ue2   10.99.1.2/24  <->  10.99.1.1     plus a /32 back to 10.99.0.1
```

> Note: the namespace is not a convenience. In the host's, uplink is dropped
> before it is forwarded — §7.4.

### 3.3 Start a UE

```bash
sudo ./deploy/deploy-external.sh ue 1
```

It needs a profile from §3.1 and a ready UPF. Without the UPF it registers and
its PDU session is refused. Three lines say it worked:

```
  ok     registered  imsi-001010000000001
  ok     PDU session up on uesimtun0  10.60.0.1/32
  ok     default route in ue1 is now uesimtun0
```

> Note: one AKA synchronisation failure on a first attach is normal — the core
> retries with a corrected SQN.

### 3.4 Test the data path

```bash
sudo ./deploy/deploy-external.sh ue 1 probe --probe <an address this host can reach>
```

It runs ICMP, DNS and HTTP from inside the namespace, then prints `upfgtp`'s
counters. **RX and TX both climbing** is the only thing that proves the tunnel
carried the traffic; a few TX errors are cosmetic. Pass `--probe` to `ue start`
to run this as soon as the session comes up.

> Note: do not point `--probe` at `8.8.8.8` without testing it from the host
> first — §7.5.

### 3.5 Stop

```bash
sudo ./deploy/deploy-external.sh ue 1 stop     # that UE and its namespace
sudo ./deploy/deploy-external.sh stop          # UEs, then the gNB, then the UPF
```

## 4. Reach a running gNB or UE

`cli` opens UERANSIM's `nr-cli` console on a node, in whichever namespace that
node lives in:

```bash
./deploy/deploy-external.sh cli               # list the nodes, and the command for each
./deploy/deploy-external.sh cli gnb           # console on the gNB
sudo ./deploy/deploy-external.sh cli ue 1     # console on UE 1 — root, it is in a namespace
```

Append a command to run just that one and exit:

```bash
./deploy/deploy-external.sh cli gnb ue-list
sudo ./deploy/deploy-external.sh cli ue 1 ps-list
```

| | |
|---|---|
| **UE** | `info` `status` `timers` `rls-state` `coverage` `ps-list` `ps-establish` `ps-release` `ps-release-all` `deregister` |
| **gNB** | `info` `status` `amf-list` `amf-info` `ue-list` `ue-count` `ue-release` |

`commands` inside either console prints the same list. The verbs that run a
procedure move the counters on `/state`.

For anything `cli` does not cover, enter the namespace yourself, as root:

```bash
sudo ip netns exec ue1 ip -br addr           # the veth and uesimtun0
sudo ip netns exec ue1 ip route              # default should be uesimtun0
sudo ip netns exec ue1 tcpdump -ni uesimtun0
sudo ip netns exec ue1 bash
grep upfgtp /proc/net/dev                    # from the host — the gNB is in the host's namespace
```

## 5. Run all of it at once

`e2e` drives every stage above in order and gives each one a verdict.

```bash
kubectl -n volantis get svc gateway-svc pran-svc
kubectl -n volantis port-forward svc/udr-mongo 27017:27017 &

sudo ./deploy/deploy-external.sh e2e \
    --pran <pran-svc IP> --gateway <gateway-svc IP> --probe <an address this host can reach>
```

```
Verdict
  pass    Requirements          pass    N4
  pass    Subscribers           pass    Registration and PDU session
  pass    NG Setup              pass    Data path
```

Omit `--probe` and the last stage reports `skipped`, not `pass`. Nothing is torn
down, so a failed stage is still there to look at. Finish with
`sudo ./deploy/deploy-external.sh stop`.

Or take the same six steps by hand, in this order:

```bash
./deploy/deploy-external.sh check --pran <pran-svc IP> --gateway <gateway-svc IP>
./deploy/deploy-external.sh subscribers
./deploy/deploy-external.sh gnb
sudo ./deploy/deploy-external.sh upf
sudo ./deploy/deploy-external.sh ue 1
sudo ./deploy/deploy-external.sh ue 1 probe --probe <an address this host can reach>
```

## 6. Status, logs, and the files

```bash
./deploy/deploy-external.sh status            # the settings, and what is up
./deploy/deploy-external.sh logs upf          # upf | gnb | ue-1
./deploy/deploy-external.sh check upf         # one phase: addresses db gnb upf ue all e2e
./deploy/deploy-external.sh                   # every option, with its default
```

Logs are in `deploy/run/external/log/`. Settings resolve flag > environment >
saved > default.

```
lib.sh  settings and helpers          upf.sh  the UPF, the pod route, ue1's namespace
check.sh  requirements, per phase     ue.sh   one UE in its namespace, and the probe
subscribers.sh  uegen                 cli.sh  nr-cli, in the node's namespace
gnb.sh  nr-gnb and the radio link     e2e.sh  all of it, with a verdict
config/  the four templates — rendered into run/external/generated/, never edited in place
```

---

## 7. Why, and what goes wrong quietly

Skip this until something misbehaves.

**7.1 The UPF anchors nothing.** The anchor set is *derived* — the DNNs its `n6`
face serves, against what NSM declares — not configured. A `--tran` naming a
transport network NSM does not declare, or a slice/DNN pair it does not, leaves
the UPF up, registered, ready and refusing every session. `upf start` reports
`Anchored data networks: []` as a failure but leaves the process running. Stop
it, fix `--tran` or the slices in `config/upf.json`, start it again.

A UPF that **never becomes ready** is the other half of this. It is a mesh
consumer too: it pulls its data networks from NSM, and NSM is a pod at a pod
address. A host that reaches only the `LoadBalancer` addresses — minikube with
`minikube tunnel` — never finishes that pull. `--pod-cidr` and `--node-ip` give
it the route; `stop` removes it again.

**7.2 A gNB reports itself attached even when its sockets did not bind.** NG
Setup runs over SCTP and says nothing about the radio link or N3, so an `nr-gnb`
that lost either to something already holding the address completes it, logs
success, and then finds no cell for any UE. `gnb start` fails on `Socket bind
failed` and names the address. The usual culprit is an `nr-gnb` left from an
earlier run holding `<link>:4997` or `<gnb-ip>:2152`; find it with `ss -lnup`.

No NG Setup at all within 20s is about `--pran` instead: a `LoadBalancer`
address with nothing publishing it times out exactly like a wrong address.

**7.3 Subscribers can go into the wrong database, and nothing says so.** If this
host already runs a MongoDB on 27017, the forward cannot take the IPv4 address
and binds only `[::1]:27017` — one `Forwarding from` line instead of two, exit 0.
`uegen` then writes every subscriber into the *host's* database, and the
reachability check passes because something answered. It surfaces minutes later
as a rejected Registration, with the cause only in the UDM's log:

```
GenerateAuthData for suci-... failed: Load authentication context for imsi-...
  <<= Read subscription data from database <<= mongo: no documents in result
```

Forward to a free port and say so — `port-forward svc/udr-mongo 27018:27017`
with `--db mongodb://127.0.0.1:27018`. Two `Forwarding from` lines, one of them
`127.0.0.1`, is a good forward.

**7.4 Why each UE needs its own namespace.** In the host's, the UE's address
from the pool is a *local* address: the kernel drops decapsulated uplink as
`martian source ... on dev upfgtp` before FORWARD, and the UE's own copy shares a
conntrack entry with the forwarded one so the masquerade never applies. That is
also why the gNB's radio link moves onto `ue1`'s veth, and why the namespace's
default route goes onto `uesimtun0` once the session is up — otherwise only a
bound probe (`ping -I`) uses the tunnel and every application test silently
leaves by the veth, which nothing masquerades. The `/32` back to the gNB keeps
UEs other than `ue1` attached across that route change.

**7.5 Judging the data path.** A network that blocks ICMP to `8.8.8.8` makes a
working tunnel look exactly like a broken one, because the host's own ping fails
identically. Pick a target the host answers for, and read
`grep upfgtp /proc/net/dev` before believing any probe.

`Invalid SDFFilter, PDR will match without it` should not appear. If it does,
the PCC rule's filter is being dropped and the PDR matches wider than the rule
says — no policy is enforced. Judge a rule set by the kernel's own table
(`bin/gtp5g-tunnel list pdr`), never by the absence of warnings: a filter
silently the wrong way round produces no warning at all.

**7.6 The gNB and the UPF need two addresses on one host.** Both bind GTP-U's
2152, and TS 29.281 fixes it in both directions — it is the local bind port *and*
the `OUTER_HEADER_CREATION_PORT` of every downlink tunnel. The UPF binds its
`n3` address rather than the wildcard, which is what makes sharing a host
possible; the usual minikube case resolves to two addresses unasked. Where it
cannot, `check` says so — give `--gnb-ip` and `--upf-ip`, or use two hosts.

**7.7 Why `cli` exists.** nr-cli's two halves disagree about namespaces.
Discovery is `/tmp/UERANSIM.proc-table`, which every namespace shares, so
`nr-cli -d` lists a UE from the host and looks like it will work. The command
channel is a loopback socket, and loopback is per-namespace, so a command issued
from the host hangs with no error and no timeout. `cli` knows which namespace
each node is in, and bounds the one-shot form at 20s.

**7.8 Why these run outside the cluster.** The UPF's data path needs the `gtp5g`
kernel module on the host; otherwise it is an ordinary Volantis network
function. UERANSIM is the radio, which is what the deployment is tested *with*.
Nothing else is outside — in single-cloud even Proxy-RAN runs in the cluster,
behind an SCTP `LoadBalancer`.
