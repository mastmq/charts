# charts

Helm charts for mast. One chart, `charts/mast`, published as an OCI artifact to `oci://ghcr.io/mastmq/charts`.

## The chart deploys two shapes, and both must render

`mode: standalone` — one all-in-one pod, file-backed JetStream, no cluster. An edge site, a lab, or anything small enough not to want two tiers.

`mode: cluster` (the default) — a `core` StatefulSet holding Raft and the KV buckets, and an `edge` Deployment that terminates MQTT and joins the core as NATS leaf nodes. They are split because they have opposite operational shapes: core wants stable peers and volumes; edge scales with connection count and restarts on every deploy. Coupling them turns every autoscale event into Raft membership churn.

Templates are named for the shape they serve (`core-*`, `edge-*`, `standalone-*`). **A change to one shape is not a change to the other** — `helm template` both before pushing, which is what `ci/*-values.yaml` and the lint workflow exist to force.

## Adding a values key

1. Add it to `values.yaml` **with a comment saying why it exists**, not what it is. Every key in that file already carries one; a bare key is out of place.
2. Wire it into the templates for every mode it applies to.
3. If it maps to a `mast` config field, the field must already exist in `mastmq/mast`'s `configs/config.example.toml`. The chart writes a TOML ConfigMap — a key the broker does not read is silently ignored, which is the worst kind of wrong.
4. Document it in `charts/mast/README.md`.
5. If it changes a rendered shape, add or extend a file in `charts/mast/ci/`.

## Things learned the hard way, encoded in the defaults

**OpenShift security context.** The restricted SCC assigns a uid from the namespace range and rejects a pod that asks for its own. Overriding `podSecurityContext` requires **explicit `null`s**, not `{}` — Helm deep-merges maps, so an empty map leaves the chart defaults in place and the pod is refused.

**`GODEBUG=multipathtcp=0`.** Go enables multipath TCP on listeners from 1.24 and the OpenShift dataplane does not handle it: connections are accepted and then every read fails with `permission denied`. It looks exactly like a broker fault. `extraEnv` exists partly for this and the values file says so.

**`workloadAnnotations` is separate from `podAnnotations` on purpose.** A StatefulSet's selector is immutable, so replacing another broker under the same name fails mid-migration with `updates to statefulset spec ... are forbidden`. Under Argo CD, `argocd.argoproj.io/sync-options: Replace=true` on the workload lets the sync delete and recreate it. That annotation has to land on the workload, not the pod template.

**`internalPort` and `wsPort` default to 0, meaning disabled.** The internal listener skips authentication and authorization entirely — whatever reaches it is trusted completely. Never expose it beyond the cluster.

**`auth.http.wire: emqx`** speaks EMQX v5's http backend shape so an auth service written for EMQX works unchanged. EMQX has no tenant concept, so `auth.tenantDefault` applies in that mode.

**`podDisruptionBudget` on edge is on by default with `maxUnavailable: 1`.** A deploy that cycles every edge pod at once reconnects the whole fleet at once, and correlated reconnects are the failure mode that actually hurts.

## CI

`lint.yaml` runs on every push and PR:

- `helm lint`
- `helm template` with default values **and with every file in `ci/`** — a template that only renders under defaults is a template that breaks the first time someone turns a feature on
- `kubeconform -strict` against real Kubernetes schemas, which `helm lint` does not do

Helm is pinned to **v4.3.0** in both `lint.yaml` and `release.yaml`, deliberately matched to the version people run locally. Validating against 3.x while the chart is authored against 4.x means a template can pass one and fail the other — and in the release job it would ship. If you bump one, bump both.

## Releasing

`release.yaml` fires on a tag matching **`mast-*`** (not `v*`), packages the chart and pushes it to `oci://ghcr.io/mastmq/charts`.

Bump both fields in `Chart.yaml`: `version` is the chart's, `appVersion` is the broker's. They are not required to match and should not be bumped together out of habit — a chart-only fix bumps `version` alone.

```console
$ helm install mast oci://ghcr.io/mastmq/charts/mast
```

Artifact Hub registration is still open work; it needs a Helm repo index published somewhere before the listing can point at anything.

## Conventions

Conventional commits with the chart as scope: `feat(mast):`, `fix(mast):`, or bare `ci:` / `docs:` for repo-level work. Markdown one paragraph per line.
