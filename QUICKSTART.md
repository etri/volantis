# Quickstart

This guide brings up a **single-cluster, control-plane-only** Volantis deployment and
runs a UE registration procedure against it. It then changes the routing policy by
editing a service definition — without touching any network function — which is the
central idea of the system.

**Scope.** No UPF, no `gtp5g` kernel module, no multi-cloud setup. Registration
completes end to end; PDU session establishment requires the user plane and is covered
separately in [`deploy/host-upf/`](deploy/host-upf/). Everything here runs on a single
machine.

**Time:** about 15 minutes.

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes cluster | Minikube is fine; 4 vCPU / 8 GB RAM is enough for this guide |
| `kubectl` | Configured for the target cluster |
| `helm` | v3 |
| [StormSIM](https://github.com/lvdund/StormSIM) or [UERANSIM](https://github.com/aligungr/UERANSIM) | UE/gNodeB emulator to drive signaling |

```bash
minikube start --cpus=4 --memory=8192
```

## 2. Subscriber data store

Volantis replaces the UDR with a MongoDB store accessed directly by the UDM.

```bash
kubectl create namespace volantis
helm install mongodb oci://registry-1.docker.io/bitnamicharts/mongodb \
  --namespace volantis
```

Provision the sample subscribers used by this guide:

```bash
kubectl apply -f config/subscribers/   # TODO: confirm provisioning job name/path
```

## 3. Install the service mesh

The mesh controller and one gateway. In a single-cluster deployment the gateway
carries no cross-cloud traffic, but it is installed so the topology matches the
multi-cloud case.

```bash
helm install volantis-mesh deploy/helm/volantis-mesh \
  --namespace volantis
```

<!-- TODO: replace local chart paths with the published chart repository once it
     exists, e.g. helm repo add volantis https://etri.github.io/volantis -->

Wait for the controller to become ready:

```bash
kubectl -n volantis rollout status deploy/volantis-controller
```

## 4. Install the core network functions

```bash
helm install volantis-core deploy/helm/volantis-core \
  --namespace volantis \
  --set upf.enabled=false          # TODO: confirm the value key that disables the UPF
```

This deploys the AMF, SMF, AUSF, UDM, PCF, NSSF, and Proxy-RAN. Each function embeds
the mesh agent and registers itself with the controller on startup.

```bash
kubectl -n volantis get pods
```

All pods should reach `Running`. Confirm that the controller sees the registered
instances:

```bash
kubectl -n volantis logs deploy/volantis-controller | grep -i register
```

## 5. Apply the service definitions

Service definitions are where deployment policy lives: they bind matching rules to a
set of producers and to routing, load-balancing, and binding policies. Network
functions never see them.

Start with the location-agnostic policy — any eligible instance may serve a request:

```bash
kubectl apply -f deploy/service-definitions/location-agnostic.yaml
```

## 6. Run a registration procedure

Point your emulator at the Proxy-RAN service, which terminates NGAP/SCTP:

```bash
kubectl -n volantis get svc volantis-proxy-ran
```

<!-- TODO: add the concrete StormSIM invocation and its config file for this scenario
     (a small, self-contained profile that lives in this repo), and the equivalent
     UERANSIM gnb/ue yaml. -->

```bash
# StormSIM — a small profile: a handful of UEs, registration only
stormsim -c quickstart-ues.yaml    # TODO: confirm flag, and add the profile file
```

A successful run shows the registration procedure completing. You can watch the AMF
handle it:

```bash
kubectl -n volantis logs -l app=volantis-amf --tail=50
```

## 7. Change the routing policy — the payoff

Now scale the SMF to several replicas and give them differing locality labels, so that
a routing policy has something to choose between:

```bash
kubectl -n volantis scale deploy/volantis-smf --replicas=3
```

<!-- TODO: document how instance attributes (labels) are assigned per replica —
     via chart values, or per-deployment. This step needs the real mechanism. -->

Apply the location-aware definition. It differs from the location-agnostic one only in
its routing rule:

```bash
diff deploy/service-definitions/location-agnostic.yaml \
     deploy/service-definitions/location-aware.yaml

kubectl apply -f deploy/service-definitions/location-aware.yaml
```

Re-run the registration procedure from step 6. Requests carrying a locality hint are
now steered to instances in the matching location.

**No network function was rebuilt, reconfigured, or restarted.** The controller
distributed the updated definition to the consuming agents, and selection changed at
the routing layer. The same mechanism drives multi-cloud location-aware routing, where
the locality maps to a cloud domain rather than to a label within one cluster.

## 8. Clean up

```bash
helm uninstall volantis-core volantis-mesh mongodb --namespace volantis
kubectl delete namespace volantis
```

---

## Next steps

- **User plane.** Add a UPF to establish PDU sessions — see
  [`deploy/host-upf/`](deploy/host-upf/). The UPF runs on the host, not in the
  cluster, because its kernel data plane requires the `gtp5g` module.
- **Elastic scaling.** Enable the capacity-driven autoscaler, which scales the AMF and
  SMF on control-plane occupancy rather than CPU.
- **Multi-cloud.** Gateways federate separate clusters into one mesh, carrying
  cross-cloud service calls over mTLS while intra-cloud calls stay direct. A
  multi-cloud deployment guide will follow in a later release.
