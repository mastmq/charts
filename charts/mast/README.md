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

Headers are rendered into a Secret and reach the process as environment variables, so a token never sits in a ConfigMap. Point `auth.http.existingSecret` at a Secret you manage yourself if you would rather the chart never saw it. It is loaded with `envFrom`, so its keys are environment variable names rather than header names: the header upper-cased, hyphens turned into underscores, behind `MAST__AUTH__HTTP__HEADERS__`. `Authorization` is `MAST__AUTH__HTTP__HEADERS__AUTHORIZATION` and `X-Api-Key` is `MAST__AUTH__HTTP__HEADERS__X_API_KEY`. A key without that prefix is ignored without an error, which is why a Secret keyed by bare header names looks correct and sends nothing.

Two behaviours worth knowing before you go live. Authorization is asked on **every publish**, so it is cached — set `cacheTtl: 0s` if decisions must take effect instantly and accept a network round trip per message. And authentication **always fails closed** whatever `onError` says, because admitting a connection whose tenant is unknown would mean inventing an isolation boundary; `onError` governs authorization only.

### Verifying a token instead

`auth.mode: jwt` checks a signed token locally, so a reconnect storm of tens of thousands of devices touches no service at all. The trade is that revocation is only as fast as token expiry. A signature says who a client is, not what it may do, so most deployments keep `auth.http.authzUrl` set alongside it and let a policy service decide topics.

```yaml
auth:
  mode: jwt
  http:
    authzUrl: https://policy.internal/mqtt/acl
  jwt:
    algorithms: [RS256]
    keySecret: mast-jwt        # a Secret you create
    publicKeyKey: jwt.pub      # or hmacSecretKey, never both
    tenantClaim: tenant
```

The key never goes in values: the chart mounts the Secret you name at `/etc/mast/jwt` and points the broker at the one key in it. It refuses to render without `algorithms`, because accepting whatever algorithm a token asks for is how `alg: none` and RSA-to-HMAC confusion attacks work.

## TLS

Set `tls.secretName` to a Secret of type `kubernetes.io/tls`, such as one cert-manager writes. Every pod that terminates MQTT mounts it, and the MQTT listener (and the WebSocket one, when enabled) then speaks only TLS, on the same container port. Set `edge.service.mqttPort: 8883` if clients expect the conventional TLS port. The internal listener stays plain: it is for in-cluster peers, which it trusts completely anyway.

## Services

Each shape gets two Services, and only one of them is meant to be reachable from outside.

| Service | Type | Ports |
| --- | --- | --- |
| `<fullname>` (standalone) or `<fullname>-edge` (cluster) | `edge.service.type` | `mqtt`, and `mqtt-ws` when `edge.wsPort` is set |
| the same name with `-internal` appended | always `ClusterIP` | `mqtt-internal` when `edge.internalPort` is set, `metrics`, `monitor` (8222) |

The split exists because `edge.service.type: LoadBalancer` used to publish everything on one Service: the internal listener, which skips authentication and authorization entirely, the metrics port, which also serves `/debug/pprof`, and the NATS monitor. The internal Service is still reachable from any pod in the cluster, so pair `edge.internalPort` with a NetworkPolicy if the cluster is shared.

**Upgrading from 0.1.x:** anything that reached the internal listener, metrics or the monitor through the public Service name has to use the `-internal` name instead. The ServiceMonitor follows on its own, since it selects by the `metrics` port name.

## Values

| Key | Default | Notes |
| --- | --- | --- |
| `mode` | `cluster` | `cluster` or `standalone` |
| `image.repository` | `ghcr.io/mastmq/mast` | |
| `core.replicas` | `3` | StatefulSet size |
| `core.jetstreamReplicas` | `3` | Must not exceed `core.replicas`; the chart refuses to render if it does |
| `core.podDisruptionBudget.maxUnavailable` | `1` | Keeps a Raft majority through a drain |
| `core.persistence.size` | `10Gi` | Per core pod |
| `edge.replicas` | `2` | Ignored when autoscaling is on |
| `edge.maxWritesPending` | `1024` | Per-client outbound queue; multiplies by connections per pod |
| `edge.autoscaling.enabled` | `false` | Scales down one pod at a time by design |
| `edge.podDisruptionBudget.maxUnavailable` | `1` | |
| `edge.service.type` | `ClusterIP` | Applies to the client-facing Service only |
| `edge.internalPort` | `0` | Unauthenticated listener, on the `-internal` Service only |
| `auth.http.existingSecret` | `""` | Keys are `MAST__AUTH__HTTP__HEADERS__<NAME>`, not header names |
| `auth.mode` | `static` | `static`, `http` or `jwt` |
| `auth.http.onError` | `deny` | Authorization only |
| `auth.http.cacheTtl` | `1m` | `0s` disables caching |
| `auth.jwt.algorithms` | `[]` | Required in `jwt` mode; no default on purpose |
| `auth.jwt.keySecret` | `""` | A Secret you manage, mounted at `/etc/mast/jwt` |
| `auth.jwt.hmacSecretKey`, `auth.jwt.publicKeyKey` | `""` | The key in that Secret; exactly one |
| `tls.secretName` | `""` | A `kubernetes.io/tls` Secret; the MQTT listener then speaks only TLS |
| `fabric.durableQoS` | `true` | Stores QoS 1 and 2 on a replicated stream before acknowledging, so they survive a node being cut off; `false` makes them at-most-once across nodes |
| `fabric.durableMaxAge` | `5m` | How long a node can be cut off and still catch up |
| `tracing.enabled` | `false` | OpenTelemetry traces of the message path, on edges and the standalone pod; see [Tracing](#tracing) |
| `tracing.endpoint` | `""` | The OTLP/HTTP collector, e.g. `http://otel-collector.monitoring:4318` |
| `tracing.sampler`, `tracing.samplerArg` | `""` | An `OTEL_TRACES_SAMPLER` name and its ratio as a string; each empty one defers to its variable |
| `tracing.existingSecret` | `""` | A Secret you manage whose keys are `OTEL_*` variables, for `OTEL_EXPORTER_OTLP_HEADERS` |
| `session.expiry` | `24h` | How long a persistent session is kept after DISCONNECT |
| `networkPolicy.enabled` | `false` | MQTT from anywhere; internal listener, metrics and monitor from this namespace and `networkPolicy.internalFrom` only |
| `metrics.enabled` | `true` | Publishes the metrics port on the `-internal` Service. The pod serves it either way, because readiness uses it |
| `metrics.serviceMonitor.enabled` | `false` | Needs the Prometheus operator CRDs. Scrapes edges, standalone and cores |
| `metrics.grafanaDashboard.enabled` | `false` | A ConfigMap for the Grafana sidecar; see [Monitoring](#monitoring) |
| `metrics.grafanaDashboard.labels` | `grafana_dashboard: "1"` | The label the sidecar watches for |
| `metrics.grafanaDashboard.annotations` | `{}` | e.g. `grafana_folder` |
| `metrics.prometheusRule.enabled` | `false` | Needs the Prometheus operator CRDs; see [Monitoring](#monitoring) |
| `metrics.prometheusRule.labels` | `{}` | Whatever your Prometheus selects rules by, e.g. `release: kube-prometheus-stack` |
| `metrics.prometheusRule.queuerAwaySessionsThreshold` | `0` | Alert when the queuer keeps more absent sessions than this for an hour; `0` turns it off |

Run `helm show values oci://ghcr.io/mastmq/charts/mast` for the full list, each key with a comment saying why it exists.

The chart ships a `values.schema.json`, so Helm checks values before it renders anything. A wrong type (`replicas: three`, an unquoted `image.tag: 1.0`), a misspelt key (`edge.replica`), a value outside an enum (`auth.mode: ldap`) and the auth combinations the broker refuses at startup (`auth.mode: http` without `authnUrl`; `auth.mode: jwt` without `algorithms`, `keySecret` and exactly one of `hmacSecretKey` and `publicKeyKey`) all fail `helm install` with the path of the bad value, instead of rendering a pod that crash-loops. Keys under Kubernetes objects (`resources`, `affinity`, `podSecurityContext`, …) are not checked beyond their type, and `podSecurityContext` keys may be `null` on purpose.

## Monitoring

Every pod serves `/metrics`, `/healthz`, `/readyz` and `/debug/pprof` on `metrics.port`. Three add-ons build on it, all off by default because each needs something the cluster may not have.

`metrics.serviceMonitor.enabled` scrapes every role through the Prometheus operator. The other two assume this scrape, or one that adds the same `namespace`, `service` and `pod` labels.

`metrics.grafanaDashboard.enabled` renders a ConfigMap holding a Grafana dashboard, labelled for the Grafana sidecar (kube-prometheus-stack runs one). It shows connections, messages and auth failures by tenant, the durable stream's readers and publish failures, offline queueing and the queuer, the NATS client's slow consumers and reconnects, and the process. The JSON is `dashboards/mast.json` in the chart, so it can also be imported by hand.

`metrics.prometheusRule.enabled` renders a PrometheusRule:

| Alert | Fires when |
| --- | --- |
| `MastEdgeCannotReachCore` | An edge has been not-Ready for 5 minutes. `/readyz` on an edge fails while its leaf link to the core is down |
| `MastCoreNotReady` / `MastNotReady` | A core, or the standalone pod, has failed the JetStream health check for 10 minutes |
| `MastMetricsDown` | A pod has not answered a scrape for 5 minutes |
| `MastDurablePublishFailures` | Any QoS 1 or 2 publish was refused because the durable stream would not store it |
| `MastDurableReaderStalled` | One reader of the durable stream (a bridge or a queuer) read nothing for 20 minutes while others did |
| `MastSlowConsumer` | A node discarded accepted messages because a NATS subscription overflowed |
| `MastQueuersDisagree` | The cores' queuers report different numbers of away sessions for 30 minutes (cluster only) |
| `MastQueuerBacklog` | The queuer keeps more absent sessions than `queuerAwaySessionsThreshold` for an hour (when set) |

The readiness alerts read `kube_pod_status_ready` from kube-state-metrics rather than anything mast exports, because a pod that cannot serve often cannot say so either. The durable and queuer alerts are left out when `fabric.durableQoS` is off, since nothing then reads the stream.

## Tracing

`tracing.enabled` makes every edge, or the standalone pod, export OpenTelemetry traces of the message path over OTLP/HTTP: `mqtt.publish` where a message arrives, the durable store and the NATS publish under it, and `mqtt.deliver` on every node that delivers it. Cores build no tracer, since they have no MQTT side. It needs a mast release that reads `[tracing]`; older ones ignore it.

```yaml
tracing:
  enabled: true
  endpoint: http://otel-collector.monitoring:4318
  sampler: parentbased_traceidratio
  samplerArg: "0.01"
  existingSecret: mast-otel   # holds OTEL_EXPORTER_OTLP_HEADERS
```

For a fleet, sample with `parentbased_traceidratio`: the ingress decides once per message and every delivering node follows, so a trace is whole or absent. With `sampler` empty every message is traced, which costs about 13% more CPU per message. An MQTT 5 client that sends a `traceparent` user property gets the publish inside its own trace, but its sampled flag never overrides the ratio.

A collector's API key goes in `OTEL_EXPORTER_OTLP_HEADERS` (`authorization=Bearer …`) in the Secret named by `tracing.existingSecret`, never in values. Any other `OTEL_*` variable (`OTEL_RESOURCE_ATTRIBUTES`, `OTEL_BSP_MAX_QUEUE_SIZE`, …) can go there too, or in `extraEnv`. The `[tracing]` block is rendered only when tracing is on, so upgrading the chart with it off does not roll the edges.

## Network policy

`networkPolicy.enabled` adds a policy per role. On an edge or a standalone pod, MQTT and MQTT over WebSocket are open to anyone who can route to the pod, and the unauthenticated internal listener, metrics (which serves pprof) and the NATS monitor are open only to pods in the release's namespace and to the peers in `networkPolicy.internalFrom`. A core accepts only from the same set.

Kubernetes network policies can only add allowed traffic, never subtract it. In a namespace that already allows everything from everywhere — OpenShift projects commonly carry an `allow-from-all-namespaces` policy — enabling this restricts nothing, and the internal listener stays reachable cluster-wide. Check `kubectl get networkpolicy` before relying on it, and if the namespace allows everything and the internal listener is not needed, set `edge.internalPort: 0` instead.

## Operational notes

Replacing an edge pod reconnects every device attached to it, so the Deployment rolls with `maxUnavailable: 0` and the autoscaler scales down one pod at a time behind a ten-minute stabilization window. Do not loosen either without knowing what a fleet-wide reconnect does to your auth service.

Budget edge memory at roughly 40–80KB per TLS connection plus headroom, and remember that `maxWritesPending` multiplies by connections **per pod**, not by the whole fleet.

Every pod names its embedded NATS server after itself, through `MAST__NATS__NAME` from the downward API. Without it every pod in a role answers to the same `mast-core` or `mast-edge`, and NATS uses that name to tell servers apart: a core closes a route from a peer carrying its own name, and a leaf connection under a name already attached evicts the one before it, so edges knock each other off in turn. Setting `MAST__NATS__NAME` in `extraEnv` replaces the injected value.

Readiness on every role is mast's `/readyz`, on the metrics port; the NATS monitor on 8222 has no `/readyz`. On an edge it fails while the leaf link to the core is down, so the Service stops sending devices to an edge that could carry nothing across the cluster; the TCP check it replaces passed in exactly that state. Liveness on an edge stays the monitor's `/healthz`, because restarting every edge does not bring a core back. On a core and on the standalone pod, `/readyz` is nats-server's own JetStream health check: a meta leader, and streams current.

The core liveness probe asks `/healthz?js-server-only=true` on the monitor, which checks only that the server accepts connections; readiness keeps the full JetStream check through `/readyz`. A peer that is catching up, or a tier that has lost quorum, fails the full check exactly when it most needs to be left alone, so using it for liveness had the kubelet restart the peers that were recovering. A startup probe allows up to ten minutes for a large store to restore before liveness applies.

To confirm the edges actually attached to the core:

```console
$ kubectl exec sts/mast-core -- wget -qO- http://127.0.0.1:8222/leafz
```
