# Single-machine deployment

The whole core as ordinary processes on one host — no Kubernetes, no container
runtime, no orchestrator — driven end to end by a simulated gNB and UE.

```
  one host, one loopback address per component
  ┌────────────────────────────────────────────────────────────────┐
  │ controller 127.0.0.1:8888     gateway 127.0.0.2:7777           │
  │ nsm .3   pcf .4   ausf .5   udm .6   damf .7                   │
  │ pran .8 (38412 SCTP)   amf .9   smf .10                        │
  └───────┬──────────────────────────────────────┬─────────────────┘
          │ N2                                   │ N4
    nr-gnb 127.0.0.13 ──── N3 / GTP-U 2152 ──▶ upf 127.0.0.12
          │ radio link 10.99.0.1                 │ N6
    nr-ue  (netns ue1, 10.99.0.2)                ▼ the host's uplink
```

**You are done when** a UE holds a PDU session on `10.60.0.1` and carries ICMP,
DNS and HTTP over the tunnel.

## Prerequisites

```bash
./deploy/deploy-local.sh check            # everything a plain user can test
sudo ./deploy/deploy-local.sh check upf   # and the root-only ones
```

`check` starts nothing, reports each of the following by name, and exits non-zero
if the control plane cannot come up. It takes a phase: `core` and `cpup` are this
deployment's own; `gnb`, `upf` and `ue` are `deploy/external/`'s, run with this
deployment's addresses.

| | Needed for | Why |
|---|---|---|
| **Linux** | everything | `127.0.0.0/8` is entirely local, so the address plan needs no setup, and gtp5g and network namespaces exist |
| **The binaries in [`bin/`](../../bin)** | everything | `controller gateway nsm udm ausf pcf damf amf smf pran upf uegen`. See [bin/README.md](../../bin/README.md) |
| **MongoDB on `127.0.0.1:27017`** | everything | Volantis has no UDR — UDM, PCF and SMF read subscriber data from MongoDB directly |
| **Kernel SCTP** | registration | Proxy-RAN terminates NGAP over SCTP. Present in a stock kernel; some minimal images ship it separately |
| **`curl`** | readiness | Without it the runner reports liveness but not readiness |
| **[UERANSIM](https://github.com/aligungr/UERANSIM)** | gNB and UE | `nr-gnb`, `nr-ue`, `nr-cli`. Put its `build/` on `PATH`, or `export UERANSIM=/path/to/UERANSIM/build`. Tested on v3.2.6 and v3.3.0 |
| **the `gtp5g` kernel module** | user plane | `0.8.1 ≤ version < 0.9.20`; the UPF checks at startup and refuses anything outside. Tested on 0.8.2 and 0.8.3 |
| **root** | user plane, UE | The UPF creates a `gtp5g` netdev, installs a route and writes iptables rules; each UE runs in its own network namespace |
| **`iptables`** | user plane | `deploy/external/config/upf.json` sets `firewall.manage`, so the UPF installs its own rules |
| **an uplink interface** | user plane | Where UE traffic leaves the host. Taken from the default route unless `VOLANTIS_N6_DEV` says otherwise |
| **free addresses and ports** | everything | §7's plan. `check` reports anything already bound |

Unpack the binary bundle at the repository root:

```bash
curl -fL https://github.com/etri/volantis/releases/download/v0.1.1/volantis-v0.1.1.tar.gz | tar -xz -C .
```

Start a MongoDB if you have none:

```bash
docker run -d -p 27017:27017 --name volantis-mongo mongo
```

`jq` is optional, and only makes the mesh views readable.

## Quick start

One script drives it, [`deploy/deploy-local.sh`](../deploy-local.sh). Run it
**from the repository root**:

```bash
./deploy/deploy-local.sh check      # what this host is missing, if anything
./deploy/deploy-local.sh start      # control plane, subscribers, gNB  (no root)
sudo ./deploy/deploy-local.sh upf   # the user plane                   (root)
sudo ./deploy/deploy-local.sh ue 1  # a UE, in its own netns           (root)
```

Set `VOLANTIS_PROBE_TARGET` to an address this host can reach before `start`, and
the last shot runs the data-path tests itself.

Everything else:

```bash
./deploy/deploy-local.sh status            # what is running, and whether it is ready
./deploy/deploy-local.sh logs <name>       # tail one component's log
./deploy/deploy-local.sh subscribers list
sudo ./deploy/deploy-local.sh ue 1 probe   # the data-path tests, from a UE
./deploy/deploy-local.sh cli gnb           # an nr-cli console on the gNB
sudo ./deploy/deploy-local.sh stop         # all of it, namespaces included
```

Each shot checks its own requirements before starting anything, so a missing
`gtp5g` or an occupied port is reported by name rather than surfacing later as a
component that will not become ready.

> Note: every component logs that TLS is disabled, and that its advertised
> address is loopback. Both are correct here — §10.

---

## 1. Start the control plane

```bash
./deploy/deploy-local.sh start
```

No root. It runs the `core` and `gnb` requirement checks, starts the ten
components in deployment order, provisions the subscribers, and attaches the gNB.

```
Control plane
  controller  started (pid 3884719)
  gateway     started (pid 3884750)
  ...
  waiting for every component to pull its configuration from NSM

Subscribers
  template: deploy/external/config/ueransim/ue.yaml
  first: imsi-001011779185060
  last:  imsi-001019371990588
  stored 2 UE(s) in "volantis_udr"
  ok     2 profile(s) in deploy/run/ue, subscribers in mongodb://127.0.0.1:27017

gNB
  gnb         started (pid 3885124), radio link 127.0.0.13, N2 to 127.0.0.8:38412
  ok     NG Setup succeeded — the gNB is attached to Proxy-RAN

Status
COMPONENT    PROCESS  READY   ENDPOINT
controller   up       yes     http://127.0.0.1:8888/ready
gateway      up       yes     http://127.0.0.2:7777/mon/endpoints
nsm          up       yes     http://127.0.0.3:7001/ready
...
```

Read the log of anything stuck at `no`:

```bash
./deploy/deploy-local.sh logs udm
```

Logs and pid files go under `deploy/run/`, which is not tracked.

> Note: the start order only keeps the logs quiet. **No network function exits
> because NSM was unavailable** — each retries forever and stays
> registered-but-unselectable until it has pulled enough configuration to serve,
> which is what `/ready` reports. `start` waits for the whole set, because
> "started" is not the interesting moment.

Provisioning the subscribers and attaching the gNB are not this directory's work:
both are [`deploy/external/`](../external/README.md)'s, the same scripts a cluster
deployment runs, told this one's addresses.

## 2. The user plane, and a UE

```bash
sudo ./deploy/deploy-local.sh upf   # gtp5g, the pool route, its own iptables chains
sudo ./deploy/deploy-local.sh ue 1  # a UE, in its own network namespace
```

**This is where this README stops.** The UPF, the gNB and the UEs run outside a
cluster in every deployment, so they live once in
[`deploy/external/`](../external/README.md) — and that is where their mechanics
are: what `uegen` writes and why `-template` and `-seed` matter, the gNB's radio
link and the socket-bind trap that makes an unattached gNB report success, the
UPF's firewall chains, why a UE needs its own namespace and why its default route
has to move onto the tunnel, `nr-cli`, and the several things that go wrong
quietly.

What is particular to this deployment is only the addresses, and they are §7's
table. The runner fills them in, so **none of the `--` options in that README are
typed here**. The verbs are the same:

```bash
./deploy/deploy-local.sh subscribers list
./deploy/deploy-local.sh cli gnb            # an nr-cli console on the gNB
sudo ./deploy/deploy-local.sh cli ue 1      # and one on UE 1
sudo ./deploy/deploy-local.sh ue 1 probe    # the data-path tests
sudo ./deploy/deploy-local.sh ue 2          # a second UE, against the second subscriber
```

Two things this deployment adds:

- **`upf` checks that the control plane is already serving** before it starts
  anything. The UPF pulls its data networks from NSM before it opens N4, so a
  control plane that is not serving yet shows up as a UPF that registers and
  never becomes ready.
- **Relinking the gNB restarts it.** `upf start` creates ue1's namespace and moves
  the gNB's radio link onto `10.99.0.1`, so a UE in that namespace can reach it —
  and Proxy-RAN logs one `SCTPRead error ... bad file descriptor` as the old
  association goes away. That is a normal disconnect reported at error level, not
  a failure of this step. N2 and N3 stay on `127.0.0.13`.

Check that the core agrees at each layer:

```bash
curl -s http://127.0.0.9:7001/state    # AMF: {"uesRegistered":1,...}
curl -s http://127.0.0.10:7001/state   # SMF: {"sessionsEstablished":1,...}
curl -s http://127.0.0.12:7001/state   # UPF: {"smfsAssociated":1,...}
```

## 3. Look at the mesh

The controller and the gateway both expose a read-only view:

```bash
curl -s http://127.0.0.1:8888/mon/services  | jq   # definitions, and who serves them
curl -s http://127.0.0.1:8888/mon/endpoints | jq   # every registered instance
curl -s http://127.0.0.1:8888/mon/gateways  | jq   # gateways, and their endpoints
curl -s http://127.0.0.2:7777/mon/endpoints | jq   # this gateway's own domain
```

Read `/mon/services` first. Each definition reports how many producers matched it
and how many consumers subscribed:

```json
{
  "Name": "amf-001-01-10-100",
  "Selectors": {"app": "amf", "plmnId": "001-01", "amfset": "10-100"},
  "Stateful": true,
  "NumEndpoints": 1,
  "NumSubscribers": 0
}
```

> Note: `NumEndpoints: 0` on a definition whose instance is running is the
> signature of a **label mismatch**. Selectors and `mesh.labels` are compared as
> whole sets, exactly, so one wrong key or one wrong case means no producers.
> Check that first when discovery fails. Before the UPF starts, `upf-001-01`
> reads `NumEndpoints: 0` with one subscriber — the SMF waiting for a UPF that
> does not exist yet.

Each network function answers on its own agent port:

```bash
curl -s http://127.0.0.9:7001/ready         | jq   # registered? active? which gateway?
curl -s http://127.0.0.9:7001/state         | jq   # UE and session occupancy
curl -s http://127.0.0.9:7001/mon/services  | jq   # what this instance resolved
curl -s http://127.0.0.9:7001/metrics              # Prometheus
```

Read the core's own account of a session against the UE's:

```bash
./deploy/deploy-local.sh logs damf   # "Ue authenticated", "UeContext was forwarded to AMF"
./deploy/deploy-local.sh logs amf    # "Ue registered [212 ms]"
```

With `bin/gtp5g-tunnel` present, `./bin/gtp5g-tunnel list pdr` dumps the rule set
the kernel actually holds — the only account of a UPF's PDRs that cannot be
wrong. Judge a rule set by that, never by the absence of warnings.

## 4. More UEs, and more AMFs

More UEs is `ue 2`, `ue 3` and so on, each in its own namespace against the next
subscriber `uegen` provisioned. Raise `VOLANTIS_NUM_UES` before `start` to
provision more than two.

A second AMF is two edits. Give it its own address:

```bash
sed 's/127\.0\.0\.9/127.0.0.19/' deploy/local/config/amf.json \
  > deploy/local/config/amf-2.json
```

and add one line to the `COMPONENTS` list in `deploy/local/core.sh`:

```bash
"amf-2:amf:amf-2.json:http://127.0.0.19:7001/ready"
```

Restart, then check `curl -s http://127.0.0.1:8888/mon/services | jq` shows
`NumEndpoints: 2`.

The labels are unchanged, so the new instance matches `amf-001-01-10-100` the
moment it registers — no definition is edited and nothing else is restarted.
Everything the mesh does with replicas works here: identical labels put two
instances in the same service and group, distinct instance ids preserve session
affinity, and NSM allocates each one a unique AMF pointer at registration. What a
cloud adds is only the *actuator* that creates the replica.

## 5. Tear it down

```bash
sudo ./deploy/deploy-local.sh stop
```

UEs and their namespaces first, then the gNB, then the UPF, then the control
plane in reverse deployment order — every layer deregisters from the one below it
while that one is still there. Without `sudo` it stops what a plain user can and
says what it could not.

That order is what makes the release real rather than a kill. Stopping the UE
first releases its PDU session through the SMF, so the UPF sees the deletion
before it goes down, and only then removes the three chains it owns:

```
upf: Receive SessionDeletionRequest from SMF - seid 1
smf: SmContext is removed from session pool
upf: Removed chain nat/VOLANTIS-upfgtp-NAT
upf: Removed chain filter/VOLANTIS-upfgtp-FWD
upf: Removed chain filter/VOLANTIS-upfgtp-IN
gw:  Endpoint removed 127.0.0.12:9001 ... 127.0.0.4:9001
```

Afterwards the host is as it was found: no `upfgtp`, no veth, no namespace, no
`VOLANTIS-*` chain, and UDP 2152 free.

> Note: a UPF killed rather than asked to stop leaves its chains behind, and a new
> one does not recognise them as its own; `stop` says so if it finds any. NSM
> keeps a stopped instance's leases for two minutes unless something renews them.

## 6. When something does not work

| Symptom | Cause |
|---|---|
| a component is `up` but never `ready` | it has not pulled enough configuration from NSM to serve. `./deploy/deploy-local.sh logs <name>` says which part is missing |
| `NumEndpoints: 0` on a definition whose instance is running | a label mismatch. Selectors and `mesh.labels` are compared as whole sets, exactly |
| the UDM never becomes ready | `suciProfiles` in `nsm.json` is empty. A UDM with no profile fails authentication for every UE, so it refuses to be selectable. Null-scheme UEs do not change this |
| NSM exits at startup | `protectionScheme` is a number, not a string: a quoted value fails to unmarshal |
| the UE registers, then loops on `PDU Session Establishment Reject [NETWORK_FAILURE]` | no UPF. The SMF subscribes to `upf-001-01`, finds no producer and cannot build a path. Registration is unaffected — start the UPF |
| `GTP-U 127.0.0.12:2152 is already bound` | a UPF from an earlier run. One started outside the runner leaves no pid file, so `stop` cannot reach it — find it with `ss -lnup` and kill it by pid |
| the UE gets an address but nothing passes | the namespace's default route is not on the tunnel, or the target is one this host cannot reach either. Check `grep upfgtp /proc/net/dev` before believing any probe |
| `martian source ... on dev upfgtp` in `dmesg` | a UE running in the host's namespace instead of its own |
| the UPF is ready but `iptables -t nat -S VOLANTIS-upfgtp-NAT` says `No chain` | the UPF never got a data network from NSM |
| `Invalid SDFFilter, PDR will match without it` in the UPF log | the PCC rule's filter is being dropped and the PDR is matching wider than the rule says — no policy restriction is being enforced. It should not appear in an ordinary run |
| PRAN logs `SCTPRead error ... bad file descriptor` at error level | a normal gNB disconnect, reported at the wrong level. Known, harmless |

---

## 7. The address plan

One loopback address per component, default ports throughout. Each network
function runs **two** servers: the SBI server on 9001, and the agent server on
7001 carrying `/metrics`, `/state` and `/ready`.

| Component | Address | Ports |
|---|---|---|
| Controller | `127.0.0.1` | 8888 |
| Gateway | `127.0.0.2` | 7777 |
| NSM | `127.0.0.3` | 9001 SBI, 7001 agent |
| PCF | `127.0.0.4` | 9001, 7001 |
| AUSF | `127.0.0.5` | 9001, 7001 |
| UDM | `127.0.0.6` | 9001, 7001 |
| DAMF | `127.0.0.7` | 9001, 7001 |
| Proxy-RAN | `127.0.0.8` | 9001, 7001, **38412 NGAP/SCTP** |
| AMF | `127.0.0.9` | 9001, 7001 |
| SMF | `127.0.0.10` | 9001, 7001 |
| UPF | `127.0.0.12` | 9001, 7001, **2152 GTP-U** |
| gNB (UERANSIM) | `127.0.0.13` | N2 and N3; **2152 GTP-U** |
| MongoDB | `127.0.0.1` | 27017 |
| UE namespaces | `10.99.<n-1>.0/24` | one veth pair per UE; ue1's host side, `10.99.0.1`, carries the gNB's radio link |

The last two rows are this host's own rather than the core's, and
`deploy-local.sh` passes them to the shared scripts as `--upf-ip`, `--gnb-ip` and
`--upf-bind`. Against a cluster those are addresses read out of `kubectl`; here
they are this table.

The PLMN is the test PLMN **001-01**, with one slice (`1-010203`), one data
network (`internet`, `10.60.0.0/16`) and one AMF set (`10-100`).

## 8. The files, and the environment

The control plane, in this directory:

| File | What it configures |
|---|---|
| [`../deploy-local.sh`](../deploy-local.sh) | the one entry point: the three shots, `check`, `status`, `logs`, `stop`, and the address plan handed to `deploy/external/` |
| `lib.sh` | the address plan, and what `core.sh` and `check.sh` share |
| `check.sh` | the control plane's requirements (`core`), and whether it is serving (`cpup`) |
| `core.sh` | the ten control-plane components, in deployment order |
| `config/controller.json` | the controller's bind address, the gateway allow-list, and the **service definitions** — inline, since there is no Kubernetes to read `Service` objects from |
| `config/gateway.json` | the gateway's identity (`local`), the addresses it advertises, and how it reaches the controller |
| `config/nsm.json` | system configuration: slices, data networks, AMF sets, transport networks, the subscriber-store URL, and the SUCI profiles |
| `config/{udm,ausf,pcf,damf,amf,smf,pran}.json` | one network function each: its PLMN, its own parameters, and its mesh block |

The UPF, the gNB and the UEs, in [`deploy/external/`](../external/README.md) —
one copy, shared with the cluster deployments:

| File | What it configures |
|---|---|
| `../external/upf.sh`, `gnb.sh`, `ue.sh` | the user plane, the gNB, and one UE each |
| `../external/cli.sh` | `nr-cli` against a running node, in that node's namespace |
| `../external/subscribers.sh` | `uegen`: the subscriber store and the UE profiles |
| `../external/check.sh` | their requirements — reached as `check gnb\|upf\|ue` |
| `../external/config/upf.json` | the UPF: its interface roles, the DNNs it serves, and `firewall.manage` |
| `../external/config/uegen.json` | `uegen`'s view of the subscriber store, PLMN, slices and SUCI keys |
| `../external/config/ueransim/gnb.yaml` | a UERANSIM gNB pointed at Proxy-RAN |
| `../external/config/ueransim/ue.yaml` | the UE template `uegen` generates from |

Everything the runners generate goes to `deploy/run/generated/`, never over a
template. Beside it, `deploy/run/settings` holds what the first shot resolved —
UERANSIM's location, the probe target, the addresses — for the root shots that
`sudo` strips the environment from.

Set these before `./deploy/deploy-local.sh start`; no file above has to be edited
to run this somewhere else:

| Variable | Default | What it changes |
|---|---|---|
| `VOLANTIS_BIN` | `./bin` | where the binaries are looked for |
| `VOLANTIS_CONFIG` | `deploy/local/config` | which configuration directory is used |
| `VOLANTIS_RUN` | `./deploy/run` | where logs, pid files, provisioned profiles and rendered configs go |
| `VOLANTIS_LOG_LEVEL` | `info` | `trace\|debug\|info\|warn\|error`, passed to every component |
| `VOLANTIS_NUM_UES` | `2` | how many subscribers `start` provisions |
| `VOLANTIS_UE_SEED` | `1` | `uegen`'s seed — the same seed provisions the same subscribers |
| `UERANSIM` | searched | UERANSIM's `build/` directory, when `nr-gnb` is not on `PATH` |
| `VOLANTIS_N6_DEV` | the default route's | the interface UE traffic leaves the host by |
| `VOLANTIS_PROBE_TARGET` | unset | the address the data-path test probes. Pick one this host can reach |
| `VOLANTIS_UE_DNS` | `8.8.8.8` | the resolver a UE namespace gets, when the host's own is a local stub. Not the one the PDU session carries — that comes from `nsm.json` |
| `VOLANTIS_WITH_GNB` | `1` | `0` leaves the gNB to something else |

The address plan is the exception: it is in `lib.sh`, because the configs name the
same addresses and the two have to agree.

## 9. Certificates

To run this deployment with mutual TLS, give every process all three of
`--cert`, `--key` and `--pem`. The runner does not pass them; add them to the
`nohup` line in `core.sh`'s `start_one`, or run the components by hand.

> Note: the `suciProfiles` in `nsm.json` are **published test keys**. Replace them
> before this configuration is anything but a test, and keep the replacements out
> of version control. They are not optional — a UDM with no SUCI profile fails
> authentication for every UE.

---

## 10. Why it looks like this

Skip until you need it.

**The two warnings are correct.** Every component logs `TLS is DISABLED: no
certificate configured...` — this deployment is deliberately cleartext, and §9 is
how to change it. Each also logs `Registered address 127.0.0.9 is a loopback
address; only components on this host can reach it` — the address a component
advertises is the address its peers dial, and that is the point of a
single-machine deployment. The warning is there for the case where it is not what
you meant.

**This is not a toy mode.** The mesh is *required* to work without an
orchestrator: registration, discovery, subscription, resolution and liveness all
have to function for plain processes, and every platform-derived input has a
config-based equivalent. Here, instance labels come from `mesh.labels` in each
config instead of pod labels, and service definitions come from the controller's
config instead of Kubernetes `Service` objects. Nothing else changes.

Every mesh block has the same three parts — where to listen (`bind`), which
gateway to register with (`registrar`), and the labels this instance publishes:

```json
"mesh": {
  "bind": { "address": "127.0.0.9" },
  "registrar": "127.0.0.2",
  "labels": { "app": "amf", "plmnId": "001-01", "amfset": "10-100" }
}
```

Those labels are matched against the selectors of a service definition in
`controller.json`, and the match is **exact set equality**. The same keys appear
in three places — a definition's selectors, an instance's labels, and the
attribute set a consumer names a service by — and all three must use one
vocabulary.

**Distinct addresses rather than distinct ports**, because that is what a real
deployment does: an instance advertises one address and its two default ports, and
a second replica is a second address with the same ports. Adding an AMF here is
the same operation as adding a pod.

It is also what lets the UPF and the gNB share a host. Both need UDP 2152 —
`TS 29.281` fixes it, and it is not configurable, because the same value is both
the local bind port and the `OUTER_HEADER_CREATION_PORT` programmed into every
downlink tunnel. The UPF has one GTP-U face, so it binds that face's address
rather than the wildcard, and the two coexist on `127.0.0.12` and `127.0.0.13`.

**The runner enters the repository root before it starts anything**, so every
component's working directory is the root no matter where it was invoked from.
Configuration may name a relative path — `nsm.json`'s lease store is
`deploy/run/nsm-leases.json` — and a run started from inside `deploy/` would
otherwise build a second `deploy/deploy/run/` and lose the leases the first one
holds. It also means a relative `VOLANTIS_BIN`, `VOLANTIS_CONFIG` or
`VOLANTIS_RUN` is relative to the root.

**One UPF, anchoring one data network.** That is the whole user plane here: no
intermediate UPF, no uplink classifier, no second anchor. Those shapes are
implemented in the UPF and the SMF, but they need per-topology configuration and
host routing this deployment deliberately does not carry.

**Verified end to end on 2026-08-27**, with UERANSIM v3.3.0 and gtp5g 0.8.3: ten
components ready with no `level=error`, subscribers provisioned, NG Setup, 5G-AKA
over SUCI, the DAMF-to-AMF handover, a PDU session on `10.60.0.1`, and ICMP, DNS
and HTTP over the tunnel with `upfgtp` counting in both directions.
