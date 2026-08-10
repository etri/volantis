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

| Component | Image | Manifest | Source |
|---|:--:|:--:|:--:|
| Mesh Controller | ⏳ | ✅ | ⏳ |
| Gateway | ⏳ | ✅ | ⏳ |
| Mesh Agent | in NF images | — | ⏳ |
| Proxy-RAN | ⏳ | ✅ | ⏳ |
| AMF | ⏳ | ✅ | ⏳ |
| SMF | ⏳ | ✅ | ⏳ |
| UPF | ⏳ | host config | ⏳ |
| AUSF | ⏳ | ✅ | ⏳ |
| UDM | ⏳ | ✅ | ⏳ |
| PCF | ⏳ | ✅ | ⏳ |
| NSM (extended NSSF) | ⏳ | ✅ | ⏳ |
| Autoscaler | ⏳ | ✅ resource only | ⏳ |

✅ available · ⏳ pending

**Images aren't published yet.** The manifests reference our internal registry
(`192.168.0.14:5000`). Retag and push to a registry your cluster can reach until public
images land.
<!-- TODO: publish images, then update every manifest and flip the Image column. -->

The **mesh agent** is a library linked into each network function, not a sidecar, so it
has no image of its own.

The **autoscaler**'s `NFAutoscaler` resources are in `deploy/manifest/`, but the
controller that reconciles them isn't yet.
<!-- TODO: add the NFAutoscaler controller manifest. -->

The **UPF** isn't a cluster workload. Its data path needs the `gtp5g` kernel module on
the host, so it's configured with [`deploy/config/upf.json`](deploy/config/upf.json).

## Repo content

| | |
|---|---|
| Kubernetes manifests | ✅ |
| Service definitions | ✅ in `deploy/manifest/services.yaml` |
| UPF host config | ✅ |
| Quickstart | ✅ |
| Published images | ⏳ |
| Helm charts | ⏳ |
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
