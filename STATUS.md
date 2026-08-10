# Release Status

This page records exactly what is available in this repository today, what is not yet
available, and why. It is updated with each release.

<!-- TODO: set the version/tag this table describes, e.g. v0.1.0 -->
**Current release:** `TODO`

## Source code

The full Volantis source code is **not yet published**. Its release under an
open-source license is planned and is pending approval from the institution that
manages the project. We are committed to this release and will update this repository
when approval is granted.

Until then, this repository publishes everything required to **deploy and operate**
Volantis without building from source: container images, Helm charts, Kubernetes
manifests, and sample configuration.

## Component availability

| Component | Container image | Helm chart | Source |
|---|:--:|:--:|:--:|
| Mesh Controller | ✅ | ✅ | ⏳ |
| Gateway | ✅ | ✅ | ⏳ |
| Mesh Agent (library) | n/a | n/a | ⏳ |
| Proxy-RAN | ✅ | ✅ | ⏳ |
| AMF | ✅ | ✅ | ⏳ |
| SMF | ✅ | ✅ | ⏳ |
| UPF | ✅ | host install | ⏳ |
| AUSF | ✅ | ✅ | ⏳ |
| UDM | ✅ | ✅ | ⏳ |
| PCF | ✅ | ✅ | ⏳ |
| NSSF | ✅ | ✅ | ⏳ |
| Autoscaler | ✅ | ✅ | ⏳ |

✅ available · ⏳ pending source release · n/a not separately distributed

The **Mesh Agent** is linked into each network function as a library rather than
deployed as a sidecar, so it has no image or chart of its own. It ships inside the NF
images.

The **UPF** is not deployed as a cluster workload. Its kernel data plane requires the
`gtp5g` module on the host, so it is installed directly on a node — see
`deploy/host-upf/`.

## Repository content

| Area | Status |
|---|---|
| Helm charts (`deploy/helm/`) | ✅ |
| Service definition examples (`deploy/service-definitions/`) | ✅ |
| Raw Kubernetes manifests (`deploy/manifests/`) | ✅ |
| UPF host deployment (`deploy/host-upf/`) | ✅ |
| Sample NF configuration (`config/`) | ✅ |
| Quickstart (single cluster, control plane) | ✅ |
| Full source code | ⏳ pending approval |

## External dependencies

| Dependency | Purpose | Availability |
|---|---|---|
| [StormSIM](https://github.com/lvdund/StormSIM) | UE/gNodeB emulator; large-scale signaling load | public, Apache-2.0 |
| [UERANSIM](https://github.com/aligungr/UERANSIM) | Conformance verification of Release 18 procedures | public |
| [`gtp5g`](https://github.com/free5gc/gtp5g) v0.10.2 | UPF kernel data plane | public, GPL-2.0 |
| MongoDB | Subscriber data store (replaces the UDR) | public |

## Licensing

- Deployment artifacts, configuration, scripts, and documentation: Apache License 2.0
  ([LICENSE](LICENSE)).
- Container images and prebuilt binaries: distributed for research and evaluation use
  pending the source code release.
  <!-- TODO: confirm the exact redistribution terms with the institution and state
       them here, or add LICENSE-BINARIES.md and link it. -->
