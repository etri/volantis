# Quickstart

Run a Volantis control plane on one cluster and register a UE. Then change the routing
policy without touching a network function.

No UPF and no `gtp5g` kernel module, so registration works but PDU sessions don't. Add
the user plane later with [`deploy/host-upf/`](deploy/host-upf/).

About 15 minutes.

## Before you start

| You need | Notes |
|---|---|
| A Kubernetes cluster | Minikube is fine. 4 vCPU, 8 GB RAM |
| `kubectl` | Pointed at that cluster |
| `helm` | v3 |
| [StormSIM](https://github.com/lvdund/StormSIM) or [UERANSIM](https://github.com/aligungr/UERANSIM) | To drive signaling |

## 1. Start a cluster

```bash
minikube start --cpus=4 --memory=8192
kubectl create namespace volantis
```

## 2. Install the subscriber database

Volantis has no UDR. The UDM reads subscribers from MongoDB directly.

```bash
helm install mongodb oci://registry-1.docker.io/bitnamicharts/mongodb -n volantis
kubectl apply -f config/subscribers/   # TODO: confirm path and job name
```

## 3. Install the mesh

```bash
helm install volantis-mesh deploy/helm/volantis-mesh -n volantis
kubectl -n volantis rollout status deploy/volantis-controller
```

<!-- TODO: publish the charts and replace local paths, e.g.
     helm repo add volantis https://etri.github.io/volantis -->

One gateway is installed even though this is a single cluster. It carries no traffic
here, but it keeps the layout the same as a multi-cloud deployment.

## 4. Install the network functions

```bash
helm install volantis-core deploy/helm/volantis-core -n volantis \
  --set upf.enabled=false          # TODO: confirm the values key
```

This installs the AMF, SMF, AUSF, UDM, PCF, NSSF, and Proxy-RAN. Each one registers
itself with the controller at startup.

Check they're up:

```bash
kubectl -n volantis get pods
kubectl -n volantis logs deploy/volantis-controller | grep -i register
```

## 5. Apply a service definition

Service definitions decide which instance serves a request. Start with the
location-agnostic one — any instance is eligible:

```bash
kubectl apply -f deploy/service-definitions/location-agnostic.yaml
```

## 6. Register a UE

Point your emulator at Proxy-RAN:

```bash
kubectl -n volantis get svc volantis-proxy-ran
```

```bash
stormsim -c quickstart-ues.yaml    # TODO: confirm flag, add the profile file
```

<!-- TODO: add the StormSIM profile for this scenario, plus the UERANSIM gnb/ue yaml. -->

Watch it land:

```bash
kubectl -n volantis logs -l app=volantis-amf --tail=50
```

## 7. Change the routing policy

Scale the SMF so there's something to choose between:

```bash
kubectl -n volantis scale deploy/volantis-smf --replicas=3
```

<!-- TODO: document how per-replica attributes (labels) get assigned. -->

Apply the location-aware definition. It differs from the previous one only in its
routing rule:

```bash
diff deploy/service-definitions/location-agnostic.yaml \
     deploy/service-definitions/location-aware.yaml

kubectl apply -f deploy/service-definitions/location-aware.yaml
```

Re-run step 6. Requests carrying a locality hint now go to instances in the matching
location.

Nothing was rebuilt, restarted, or reconfigured. The controller pushed the new
definition to the agents and selection changed. Across clouds this same rule maps to a
cloud instead of a label.

## 8. Clean up

```bash
helm uninstall volantis-core volantis-mesh mongodb -n volantis
kubectl delete namespace volantis
```

## Next

- **PDU sessions** — add a UPF: [`deploy/host-upf/`](deploy/host-upf/). It runs on the
  host, not in the cluster, because it needs the `gtp5g` kernel module.
- **Autoscaling** — turn on the autoscaler to scale the AMF and SMF on UE and session
  count instead of CPU.
- **Multi-cloud** — gateways federate separate clusters over mTLS. Guide coming in a
  later release.
