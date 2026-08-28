# Paper ↔ code map

The architecture paper is at `~/volantis/paper/volantis.tex` (JNCA submission,
"Volantis: A Cloud-Native and Scalable Multi-Cloud Next-Generation Mobile Core
Network"). It is the design rationale behind the code and the best explanation
of *why* the mesh looks the way it does.

`docs/why-native-mesh.md` carries the same *why* argument in code terms — why the
mesh is native rather than Istio, Envoy+xDS or NRF alone — with the costs and the
falsification conditions stated. It is the place to develop that argument, since
the manuscript is not maintained here.

The paper names several things differently from the tree. Translate before
searching.

| Paper | Code |
| --- | --- |
| Mesh Controller | `mesh/controller` |
| Gateway (L7, per cloud) | `mesh/gateway` |
| Embedded Agent (library, *not* a sidecar) | `mesh/registry` |
| Service identity / name-based routing | the mandatory **attribute set** built by `common/naming.go` — matched exactly against a service definition's selectors |
| Service definition (matching rules + producer membership + policies) | `Service`/`EpGroup` in `mesh/registry/routing.go`, `serviceman.go` |
| *match* → *route* → *balance* funnel | `Selectors.match(labels)` → `RouteMatch.isMatched(options)` → `mesh/lbs` (`random`, `roundrobin`, `recent_requests`) |
| Mandatory vs. optional request attributes | the two args of `mesh.Consumer(serviceId, options)` — both are `map[string]string`; `serviceId` is the mandatory set, `options` the optional one |
| Cloud service abstraction / deployment-time service definition | `Service` + selectors, authored in controller config or as K8s `Service` objects |
| Proxy-RAN | `nfs/pran` |
| **"extended NSSF"** (assigns AMF identities, hosts system config) | **`nfs/nsm`** — the Network Slice Manager. Same component, different name. |
| Session affinity / pinned per-context SBI client | `ConsumerWithInstanceId` + the AMF-pointer instance ID set via `ActivateSbi` |
| Capacity-driven autoscaling signal | `mesh.Options.GetState` → the agent server's `/state` endpoint |

## Known divergences between paper and code

**Work in this repo is implementing the paper's missing features. The manuscript
is not maintained here — never edit `~/volantis/paper/*.tex`, and treat every gap
below as code to write, not prose to fix.** `TODOs.md` carries the full backlog
derived from the paper's stated limitations.

**Service identity is an attribute set, as the paper describes.** A request is a
set of attributes partitioned into mandatory pairs (which identify the service)
and optional pairs (which refine selection). `common/naming.go` builds the
mandatory set — `{app: amf, plmnId: 208-93, amfset: 10-100}` — and
`mesh.Consumer(serviceId, options)` takes it directly; the identity strings it
used to compose are gone. A definition is named by its **identity**, which
defaults to its selectors: a request matches when its attribute set equals the
identity exactly, so at most one definition can match and no priority rule is
needed. A definition is named by its selectors and by nothing else, so a producer
cannot front several *declared* services — which is what a visited network needs
to declare a home network's services (`{app: udm, plmnId: 208-93}`) behind its
local SEPP (`{app: sepp, plmnId: 450-05}`). The configs under `config/roaming/`
state that intent and the controller refuses it; see the SEPP item in `TODOs.md`.
`models.ServiceKey` renders an identity
into a string for map indexing, the `serviceId` header and logs — that is an
encoding, not an identity, and nothing takes a routing decision by parsing one.
The single exception is SEPP, which reads the named `plmnId` attribute to pick a
roaming peer.

**DAMF is absent from the paper.** The paper describes Proxy-RAN selecting an AMF
from the AMF set directly, with no default-AMF stage. The implementation routes
through a separate NF, `nfs/damf`, which performs initial authentication and AMF
assignment before the UE is handed to a serving AMF —
`nfs/pran/settings/findamf.go` resolves the `damf-*` service, not `amf-*`. Follow
the code; the paper simply doesn't cover this NF.

Smaller mismatches, all paper-side staleness:

- The paper says Go 1.22; `go.mod` says 1.25.0 and the Dockerfile uses `golang:1.25.5`.
- The paper's ~150K lines counts the external `reogac/*` generated protocol and
  SBI libraries. This repo is ~50K lines of Go.
- SEPP and roaming (`nfs/sepp`, `config/roaming/{home,visit}`) are implemented but
  out of the paper's scope.
- The paper credits the UDR replacement to direct UDM→MongoDB access; in practice
  PCF and SMF also query MongoDB directly.
