# Status

What's in this repo today, and what isn't.

<!-- TODO: set the release tag, e.g. v0.1.0 -->
**Release:** `TODO`

## Source code

**Volantis will be open source.** We're waiting on approval from the institution that
manages the project, and we'll update this repo when it comes through.

Part of it is already released. The protocol layer is developed as standalone Go
libraries you can use today, with or without Volantis:
[`sbi`](https://github.com/reogac/sbi), [`nas`](https://github.com/reogac/nas),
[`ngap`](https://github.com/lvdund/ngap), [`pfcp`](https://github.com/reogac/pfcp).

What's pending is the network functions and the service mesh. You don't need them to
run the system — images, charts, manifests, and config are all here.

## Components

| Component | Image | Chart | Source |
|---|:--:|:--:|:--:|
| Mesh Controller | ✅ | ✅ | ⏳ |
| Gateway | ✅ | ✅ | ⏳ |
| Mesh Agent | in NF images | — | ⏳ |
| Proxy-RAN | ✅ | ✅ | ⏳ |
| AMF | ✅ | ✅ | ⏳ |
| SMF | ✅ | ✅ | ⏳ |
| UPF | ✅ | host install | ⏳ |
| AUSF | ✅ | ✅ | ⏳ |
| UDM | ✅ | ✅ | ⏳ |
| PCF | ✅ | ✅ | ⏳ |
| NSSF | ✅ | ✅ | ⏳ |
| Autoscaler | ✅ | ✅ | ⏳ |

✅ available · ⏳ pending source release

The **mesh agent** is a library linked into each network function, not a sidecar, so it
has no image or chart of its own.

The **UPF** isn't a cluster workload. Its data path needs the `gtp5g` kernel module on
the host — see [`deploy/host-upf/`](deploy/host-upf/).

## Repo content

| | |
|---|---|
| Helm charts | ✅ |
| Service definition examples | ✅ |
| Raw Kubernetes manifests | ✅ |
| UPF host install | ✅ |
| Sample NF config | ✅ |
| Quickstart | ✅ |
| Multi-cloud deployment guide | later release |
| Source code | ⏳ |

## Dependencies

| What | Used for | License |
|---|---|---|
| [`gtp5g`](https://github.com/free5gc/gtp5g) v0.10.2 | UPF kernel data path | GPL-2.0 |
| MongoDB | Subscriber data (replaces the UDR) | SSPL |
| [StormSIM](https://github.com/lvdund/StormSIM) | UE/gNodeB emulator | Apache-2.0 |
| [UERANSIM](https://github.com/aligungr/UERANSIM) | UE/gNodeB emulator | GPL-3.0 |

## Licensing

Everything in this repo is Apache 2.0 — see [LICENSE](LICENSE).

Container images and prebuilt binaries are for research and evaluation use until the
source is released.
<!-- TODO: confirm the binary terms with the institution, or add LICENSE-BINARIES.md. -->
