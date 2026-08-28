# Binaries

Put the binaries here. This directory ships with this README and nothing else.
Both runners — [`deploy-local.sh`](../deploy/deploy-local.sh) and
[`deploy-external.sh`](../deploy/deploy-external.sh) — look here by default and
name whatever they cannot find rather than starting anything.

Three different things end up here, from three different places.

## 1. The Volantis binaries — download one bundle

Every binary in the table below ships as a single archive. Unpack it at the
repository root:

```bash
cd /path/to/this/repo
curl -fL https://github.com/etri/volantis/releases/download/v0.1.1/volantis-v0.1.1.tar.gz \
  | tar -xz -C .
```

The archive carries a `bin/` directory holding the twelve binaries below, with
their execute bits, so unpacking it at the root puts them where every script
already looks. It contains nothing else — no `gtp5g-tunnel`, no UERANSIM.

That is all you need to run any of the deployments.

> Note: it is about 220 MB, and its version matches the published images'
> default tag, `v0.1.1`. Later releases are at
> <https://github.com/etri/volantis/releases>; take the archive of the tag you
> intend to deploy.

## 2. `gtp5g-tunnel` — build it

Optional, and the only account of a UPF's rules that cannot be wrong:

```bash
go build -o bin/gtp5g-tunnel github.com/free5gc/go-gtp5gnl/cmd/gogtp5g-tunnel
./bin/gtp5g-tunnel list pdr        # what the kernel actually holds
```

Nothing requires it. The deployments check for it, say so if it is missing, and
carry on.

## 3. UERANSIM — clone and build it

The simulated gNB and UE. Clone <https://github.com/aligungr/UERANSIM>, build it
as its README says, then either copy `nr-gnb`, `nr-ue` and `nr-cli` here or point
`UERANSIM` at its build directory:

```bash
export UERANSIM=/path/to/UERANSIM/build
```

The scripts look in `$UERANSIM` first, then on `PATH`, then here, then in the
usual build locations, and report by name which binary is missing.

## What each one is

| Binary | What it is |
|---|---|
| `controller` | Mesh controller — the global registry and the service definitions |
| `gateway` | Per-cloud gateway — local registry and L7 proxy for cross-cloud SBI |
| `nsm` | Network Slice Manager — system configuration, and AMF identity allocation |
| `pran` | Proxy-RAN — terminates NGAP/SCTP, exposes N2 as a service-based interface |
| `damf` | Default AMF — initial authentication, slice and AMF-set selection |
| `amf` | AMF — stateful per UE, serves a UE once the DAMF hands it over |
| `smf` | SMF — session management, UPF path selection |
| `upf` | UPF — user plane. Needs the `gtp5g` kernel module and root |
| `udm`, `ausf`, `pcf` | Subscriber, authentication and policy functions |
| `uegen` | Provisions subscribers, and writes the matching UERANSIM profiles |

The **mesh agent** has no binary of its own: it is a library linked into every
network function, not a sidecar.

## Common options

Every binary takes the same three:

```
  -c, --config FILE     configuration file (required)
  -l, --log FILE        write logs to FILE instead of stdout
  -v, --logLevel LEVEL  trace, debug, info, warn, error, fatal, panic
```

and the same four for transport security:

```
  --cert FILE       certificate
  --key  FILE       private key
  --pem  FILE       CA root
  --requireTls      refuse to start unless a certificate is configured
```

Give **all three** of `--cert/--key/--pem` for mutual TLS, verifying peers
against the CA root. Give **none** for cleartext, which is what a test deployment
wants and what [`deploy/local/`](../deploy/local) uses. Add `--requireTls` (or
`REQUIRE_TLS=1`) to a production deployment so cleartext itself is an error.

> Note: anything in between all three and none is a configuration error, and the
> process refuses to start. A mistyped path must not quietly become an
> unauthenticated deployment.

## Why none of this is in the repository

A git history is not a place to ship a compiled binary, least of all somebody
else's. `gtp5g-tunnel` belongs to the `go-gtp5gnl` module the UPF already depends
on; UERANSIM is another project entirely. If you hold a source checkout, `make
all` builds the Volantis set into its own `bin/` — the source release is still
pending, so that path is open only to whoever already has the tree.
