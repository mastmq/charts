# mast

Multi-tenant MQTT broker built on core NATS. See [mastmq/mast](https://github.com/mastmq/mast) for what it is and how it works.

## Install

```console
$ helm install mast oci://ghcr.io/mastmq/charts/mast
```

## The two shapes

`mode: standalone` runs a single all-in-one pod with file-backed JetStream and no cluster. It is the right answer for an edge site, a lab, or anything small enough not to need two tiers.

`mode: cluster` (the default) splits the two jobs that have opposite operational shapes. The **core** tier holds Raft and the KV buckets, so it wants stable peers and volumes and is a StatefulSet addressed by stable pod DNS. The **edge** tier terminates MQTT, scales with connection count and restarts on every deploy, so it is a stateless Deployment that joins the core as NATS leaf nodes. Running them in one workload would turn every autoscale event into Raft membership churn, which is the whole reason mast has roles.

You do not need the split until you are big. Up to roughly ten nodes, `mode: standalone` or a small core-only deployment is simpler and behaves the same.

## Authentication

The default `auth.mode: static` puts every connection in one tenant and permits every topic. That is appropriate for a lab and wrong for anything reachable by someone else; the chart prints a warning on install.

For anything real, point mast at your own service:

```yaml
auth:
  mode: http
  http:
    authnUrl: https://policy.internal/mqtt/auth
    authzUrl: https://policy.internal/mqtt/acl
    headers:
      Authorization: "Bearer ..."
```

Headers are rendered into a Secret and reach the process as environment variables, so a token never sits in a ConfigMap. Point `auth.http.existingSecret` at a Secret you manage yourself if you would rather the chart never saw it; its keys are header names.

Two behaviours worth knowing before you go live. Authorization is asked on **every publish**, so it is cached — set `cacheTtl: 0s` if decisions must take effect instantly and accept a network round trip per message. And authentication **always fails closed** whatever `onError` says, because admitting a connection whose tenant is unknown would mean inventing an isolation boundary; `onError` governs authorization only.

## Values

| Key | Default | Notes |
| --- | --- | --- |
| `mode` | `cluster` | `cluster` or `standalone` |
| `image.repository` | `ghcr.io/mastmq/mast` | |
| `core.replicas` | `3` | StatefulSet size |
| `core.jetstreamReplicas` | `3` | Must not exceed `core.replicas` |
| `core.persistence.size` | `10Gi` | Per core pod |
| `edge.replicas` | `2` | Ignored when autoscaling is on |
| `edge.maxWritesPending` | `1024` | Per-client outbound queue; multiplies by connections per pod |
| `edge.autoscaling.enabled` | `false` | Scales down one pod at a time by design |
| `edge.podDisruptionBudget.maxUnavailable` | `1` | |
| `auth.mode` | `static` | `static` or `http` |
| `auth.http.onError` | `deny` | Authorization only |
| `auth.http.cacheTtl` | `1m` | `0s` disables caching |
| `metrics.serviceMonitor.enabled` | `false` | Needs the Prometheus operator CRDs |

Run `helm show values oci://ghcr.io/mastmq/charts/mast` for the full list.

## Operational notes

Replacing an edge pod reconnects every device attached to it, so the Deployment rolls with `maxUnavailable: 0` and the autoscaler scales down one pod at a time behind a ten-minute stabilization window. Do not loosen either without knowing what a fleet-wide reconnect does to your auth service.

Budget edge memory at roughly 40–80KB per TLS connection plus headroom, and remember that `maxWritesPending` multiplies by connections **per pod**, not by the whole fleet.

To confirm the edges actually attached to the core:

```console
$ kubectl exec sts/mast-core -- wget -qO- http://127.0.0.1:8222/leafz
```
