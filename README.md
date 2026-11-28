# argocd-apps — the platform catalog

The GitOps payload for the [myLab](https://github.com/josuecodjo/myLab) homelab.
`myLab` builds the cluster and applies **one** Argo CD Application; everything
else in the cluster is declared here.

A single Helm chart turns a values catalog into one Argo CD `Application` per
component — no hand-written Application manifests, no vendored upstream charts.

```
myLab (ansible)
   └─ applies Application "base-apps" ──┐
                                        ▼
                          base-apps/ (this repo, Helm chart)
                                        │
                     ┌──────────────────┴──────────────────┐
                     ▼                                     ▼
            values.charts (Helm charts)          values.apps (git paths)
                     │                                     │
   external-secrets, kyverno, policy-reporter,    php-apache, ghost,
   falco, keycloak, argo-rollouts, kube-green,    kyverno-policy,
   kubernetes-dashboard, kube-prometheus-stack,   monitoring-extras,
   kro, kargo, vault, vault-secrets-operator      vault-demo
```

---

## Table of contents

1. [Repository layout](#1-repository-layout)
2. [How base-apps works](#2-how-base-apps-works)
3. [Common tasks](#3-common-tasks)
4. [Reference — `charts:` keys](#4-reference--charts-keys)
5. [Reference — `apps:` keys](#5-reference--apps-keys)
6. [Environment overlays](#6-environment-overlays)
7. [Sync waves](#7-sync-waves)
8. [Secrets: Vault, VSO and ESO](#8-secrets-vault-vso-and-eso)
9. [Multi-cluster: hub and spoke](#9-multi-cluster-hub-and-spoke)
10. [The DNS domain](#10-the-dns-domain)
11. [Rendering locally](#11-rendering-locally)
12. [Gotchas](#12-gotchas)
13. [The Flux track](#13-the-flux-track)

---

## 1. Repository layout

```
base-apps/                     ← the Argo CD chart. This is the entry point.
├── Chart.yaml
├── templates/
│   ├── charts.yaml            # .Values.charts -> one Application per Helm chart
│   ├── apps.yaml              # .Values.apps   -> one Application per git path
│   └── _helpers.tpl           # the syncPolicy both templates share
├── values.yaml                # THE CATALOG — chart repos, versions, namespaces
├── values-prod.yaml           # per-CLUSTER overlay: hub identity
├── values-dev.yaml            # per-CLUSTER overlay: spoke
├── values-qa.yaml             # dead - no cluster named qa
└── app_charts/<name>/
    └── values.yaml            # your values for that upstream chart

declarative/apps/<name>/       ← plain manifests Argo CD applies with kustomize
├── ghost/                       (referenced from values.apps)
├── php-apache/
├── kyverno-policy/
├── monitoring-extras/           ServiceMonitors for Argo CD's metrics
└── vault-demo/                  Vault -> VSO -> Secret -> pod, end to end

fluxCD/                        ← a parallel Flux CD implementation of the same
fluxChart/                       stack, kept for comparison. Not used by myLab.
```

Only `base-apps/` and `declarative/` are live. See
[§10](#13-the-flux-track) for the Flux directories.

---

## 2. How base-apps works

[`templates/charts.yaml`](base-apps/templates/charts.yaml) ranges over
`.Values.charts` and emits one Argo CD `Application` per enabled entry, using
Argo CD's **multi-source** feature:

```yaml
sources:
  - chart: kyverno                                   # upstream chart
    repoURL: https://kyverno.github.io/kyverno
    targetRevision: 3.8.1
    helm:
      valueFiles:
        - $values/base-apps/app_charts/kyverno/values.yaml   # your values
  - repoURL: https://github.com/josuecodjo/argocd-apps.git   # this repo,
    targetRevision: HEAD                                     # as a values ref
    ref: values
```

The second source exists only so `$values/` resolves — that's what lets your
values live in git next to the catalog while the chart itself stays unvendored.
A `ref` source must **not** carry a `path`, or Argo CD would also render this
chart from it and duplicate every child Application.

[`templates/apps.yaml`](base-apps/templates/apps.yaml) does the same for
`.Values.apps`, emitting a single-source Application pointed at a directory of
plain manifests in this repo.

Both share one `syncPolicy` from
[`_helpers.tpl`](base-apps/templates/_helpers.tpl), so the two halves can't
drift apart: `prune`, `selfHeal`, `PrunePropagationPolicy=foreground`,
`PruneLast=true`, `RespectIgnoreDifferences`, `ApplyOutOfSyncOnly`, and a
5-attempt retry with exponential backoff.

---

## 3. Common tasks

### Enable or disable a component

One line in `values.yaml`. Argo CD self-heals within ~2 minutes
(`timeout.reconciliation` is `120s`), or hit
**Refresh** on the `base-apps` app.

```yaml
charts:
  kyverno:
    enabled: true        # ← the whole change
```

### Tune a component

Edit `app_charts/<name>/values.yaml`. These are passed to the upstream chart
verbatim.

### Add a new upstream Helm chart

```yaml
charts:
  my-tool:
    enabled: true
    namespace: my-tool
    helm:
      - repoURL: https://charts.example.com
        targetRevision: 1.2.3
```

Then create `app_charts/my-tool/values.yaml` — **even if empty**. The template
always references it and Argo CD errors on a missing value file
(see [Gotchas](#12-gotchas)).

### Add a plain-manifest app

Drop the manifests in `declarative/apps/<name>/` with a `kustomization.yml`,
then:

```yaml
apps:
  my-thing:
    enabled: true
    path: declarative/apps/my-thing
    namespace: default
```

### Add a chart you maintain yourself

Put it in `app_charts/<name>/` with its own `Chart.yaml` and declare
`localChart: true`. See `kubernetes-dashboard`, which wraps the upstream chart to
add a read-only user and RBAC.

```yaml
charts:
  kubernetes-dashboard:
    enabled: true
    namespace: kubernetes-dashboard
    helm:
      - localChart: true     # tracks this repo's revision; no targetRevision needed
```

---

## 4. Reference — `charts:` keys

| Key | Type | Effect |
|---|---|---|
| `enabled` | bool | Render this Application at all |
| `helm` | list | One entry per source: `repoURL` + `targetRevision`, or `localChart: true` |
| `namespace` | str | Destination namespace (default: `dest_namespace`) |
| `project` | str | Argo CD AppProject (default: `dest_project`) |
| `chartName` | str | Chart name **and** `app_charts/` directory (default: the key) |
| `serverSideApply` | bool | Adds `ServerSideApply=true` — needed for large CRDs |
| `autosync_enabled` | bool | Set `false` to drop `syncPolicy` entirely |
| `extraValues` | map | Inline values merged over the `app_charts` file, **verbatim** |
| `templatedValues` | map | Same, but rendered with `tpl` first — use for `global.dnsName` |
| `wave` | int | `argocd.argoproj.io/sync-wave` on the Application — see [§7](#7-sync-waves) |
| `valuesFilePath` | str | Per-source: look for values in a subdirectory of `app_charts/<name>/` |

Two keys are **chart-wide**, not per-app, and matter only once there is more than
one cluster — see [§9](#9-multi-cluster-hub-and-spoke):

| Key | Type | Effect |
|---|---|---|
| `appNameSuffix` | str | Appended to every generated Application name. **Must be `""` on the hub.** |
| `clusterName` | str | Becomes Prometheus' `cluster` external label. Distinct per cluster. |
| `renderedForCluster` | str | Set by the ApplicationSet only; leave `""`. Checked against `clusterName` to refuse a render that would collide — see [§9](#9-multi-cluster-hub-and-spoke). |

---

## 5. Reference — `apps:` keys

| Key | Type | Effect |
|---|---|---|
| `enabled` | bool | Render this Application at all |
| `path` | str | Directory in the repo holding the manifests (**required**) |
| `repoURL` | str | Source repo (default: `spec.source.repoURL`) |
| `targetRevision` | str | Source revision (default: `spec.source.targetRevision`) |
| `namespace` | str | Destination namespace (default: `dest_namespace`) |
| `project` | str | Argo CD AppProject (default: `dest_project`) |
| `autosync_enabled` | bool | Set `false` to drop `syncPolicy` entirely |
| `wave` | int | `argocd.argoproj.io/sync-wave` on the Application — see [§7](#7-sync-waves) |

An entry that is `enabled` without a `path` fails the render with a clear
message rather than producing a broken Application.

> **Why not an ApplicationSet for `declarative/apps/*`?** A git *directories*
> generator exposes only `path` and `path.basename`, so you get no per-app
> namespace, no `enabled` toggle, and no per-environment differences — every
> directory becomes an app in every environment. ApplicationSets are the right
> tool when the set is open-ended and owned by someone else, which is why
> `myLab/04-ArgoCD/02-teams.yml` and `05-fleet.yml` use them. If this folder
> becomes self-service, move it to an ApplicationSet with a git **files**
> generator (a small `config.yaml` per directory), which keeps auto-discovery
> *and* per-app config.

---

## 6. Environment overlays

`values.yaml` is the catalog: it owns chart repos, versions, namespaces and sync
quirks. `values-dev|qa|prod.yaml` carry **only** differences — in practice just
`enabled` toggles.

Helm deep-merges maps, so an overlay entry inherits everything else:

```yaml
# values-dev.yaml — the whole file is ~20 lines
charts:
  kyverno:
    enabled: true    # namespace, serverSideApply and version come from values.yaml
```

**These files are now per-CLUSTER, not per-environment** — the base-apps
ApplicationSet loads `values-<cluster>.yaml`, where the name comes from the
cluster's registration Secret. See [§9](#9-multi-cluster-hub-and-spoke). The
mechanics below (deep merge, the list caveat) are unchanged; only what picks the
file has changed.

> **Caveat:** Helm *replaces* lists rather than merging them. To pin a different
> chart version in one environment you must restate the whole `helm:` entry in
> that overlay.

---

## 7. Sync waves

Child Applications carry `argocd.argoproj.io/sync-wave`, set from the `wave` key.
Argo CD syncs one wave at a time and will not start the next until every resource
in the current one is Synced **and Healthy** — and because a child Application's
health reflects its own sync, this sequences the whole platform.

| Wave | Entries | Why |
|---|---|---|
| 0 | `external-secrets`, `kyverno`, `kro`, `vault-secrets-operator` | install CRDs |
| 1 | `kube-prometheus-stack`, `policy-reporter`, `kargo`, `argo-rollouts` | need wave-0 CRDs; kps installs the Prometheus CRDs |
| 2 | `php-apache`, `ghost`, `kyverno-policy`, `monitoring-extras` | workloads and CRs |
| 3 | `vault` | see below |
| 4 | `vault-demo` | needs Vault initialised; autosync off |

This is what makes `kyverno` → `kyverno-policy` and
`kube-prometheus-stack` → `monitoring-extras` reliable rather than dependent on
Argo CD's retries.

The template uses `hasKey` rather than a truthiness test, so an explicit
`wave: 0` is emitted instead of being silently dropped. Omitting `wave` entirely
also means wave 0, since that is Argo CD's default.

**Why Vault is last.** The Vault chart's readiness probe is `vault status`, which
exits non-zero while Vault is sealed or uninitialised. A not-Ready pod never goes
Healthy, so the `vault` Application never completes — and in an early wave it
would stall every later wave behind a manual unseal step. Putting it last means a
sealed Vault blocks only `vault-demo`.

## 8. Secrets: Vault, VSO and ESO

Both operators are in the catalog, with a deliberate division of labour:

| | Vault Secrets Operator | External Secrets Operator |
|---|---|---|
| Scope | Vault only | ~20 providers (Vault, AWS, Azure, GCP…) |
| Use it for | anything **lease-managed** — dynamic DB creds, PKI | static secrets from any provider |
| CRDs | `VaultAuth`, `VaultStaticSecret`, `VaultDynamicSecret`, `VaultPKISecret` | `SecretStore`, `ExternalSecret` |
| Lease handling | renews, revokes on delete, can roll Deployments on rotation | none — a new lease per refresh, never revoked |

The driver for adding VSO is **dynamic database credentials**. Vault's database
engine issues short-lived per-app roles; ESO re-reads on an interval and neither
renews nor revokes, so it accumulates orphaned leases and swaps the Secret under
a running app. ESO stays enabled because it is provider-agnostic and the right
tool for static secrets. If you would rather run a single operator, VSO's
`VaultStaticSecret` covers static KV too — set `external-secrets.enabled: false`
and accept Vault lock-in.

### Vault's shape here

`standalone` with file storage on a `local-path` PVC. No custom HCL: the chart's
default `server.standalone.config` is already a tcp listener plus
`storage "file" { path = "/vault/data" }`, so overriding it would mean
maintaining the whole block to change nothing. The Agent Injector is disabled —
VSO does the same job through CRDs, and the injector adds a mutating webhook to
the admission path.

`server.authDelegator.enabled` stays at its default `true`: Kubernetes auth
requires Vault to call `TokenReview` to validate the ServiceAccount tokens VSO
presents.

### Mounted files refresh; env vars do not

This catches people out, so `declarative/apps/vault-demo/` is built to show it.
The same secret is delivered to one pod **both** ways:

| Delivery | On rotation |
|---|---|
| `volumeMounts` → a file | **updates** — this cluster's kubelet runs `configMapAndSecretChangeDetectionStrategy: Watch` with `syncFrequency: 1m0s`, so a new value lands within about a minute |
| `env.valueFrom.secretKeyRef` | **never updates** — captured once at container start; Kubernetes cannot change a running process's environment |

The demo page renders both panels, so rotating the value in Vault visibly moves
one and leaves the other stale. That is why VSO has `rolloutRestartTargets`: for
consumers that can only read env vars, the answer is to restart them.

It also logs every read, so the live value is visible in the **Argo CD UI's log
pane** — no port-forward, no ingress, and notably no `exec.enabled`, which stays
off.

> The demo page prints a secret over unauthenticated HTTP. That is the point of
> the demo and the reason the value must stay disposable.

### Vault needs manual initialisation

Argo CD installs Vault; it cannot initialise it. `vault operator init` and
`unseal` are one-time-per-cluster manual steps, and Vault **re-seals on every
pod restart** — so after a reboot the `vault` app sits Progressing until you
unseal. The runbook is in `myLab/README.md`.

Auth is Kubernetes auth, not AppRole, specifically to avoid the bootstrap
paradox: AppRole would need a role-id/secret-id pair planted in the cluster
first, i.e. a secret in order to fetch secrets. With Kubernetes auth nothing is
stored — Vault validates VSO's ServiceAccount token directly.

## 9. Multi-cluster: hub and spoke

One Argo CD and one Grafana, on the **hub**, supervising every cluster. Spokes run
no control plane of their own.

```
hub (prod)                                   spoke (dev)
  Argo CD ────── ApplicationSet base-apps
                   │ one root app per registered cluster
                   ├── base-apps-prod ──► children on the hub
                   └── base-apps-dev  ──────────────────────► children on dev
  Grafana ─ datasource "Prometheus"     ──► hub Prometheus
          └ datasource "Prometheus-dev" ──► dev Prometheus (own, local)
```

A cluster joins because its **registration Secret exists** and carries
`lab.homelab/managed: "true"`. No new manifest, no new template, and no cluster
API URL anywhere in git — the ApplicationSet reads `server` from the Secret.
See `myLab` step 13 for the registration and cutover procedure.

### Still works with one cluster

With only the hub registered the generator produces exactly **one** root app, and
`appNameSuffix: ""` keeps the hub's Application names byte-identical to the
single-cluster setup. Nothing about the one-cluster path changes.

### Why `appNameSuffix` exists

Both templates name each child after the bare catalog key. Every root app renders
into the **hub's** single `argocd` namespace, so without a suffix two clusters
would both produce an Application called `kyverno`, `vault`, `kargo`… — two
parents fighting over one object.

So: hub keeps `""`, spokes set `-dev` and friends. **Never set a suffix on the
hub**: it renames running Applications, which makes Argo CD delete and recreate
every component.

### One values file per cluster

The generator loads `values-<cluster>.yaml`, where `<cluster>` is the name in the
registration Secret. These files are **per-cluster**, not per-environment:

| File | Role |
|---|---|
| `values.yaml` | the catalog — shared by every cluster |
| `values-prod.yaml` | hub identity: `appNameSuffix: ""`, `clusterName: prod`, `global.dnsName` |
| `values-dev.yaml` | spoke: `-dev` suffix, Grafana off, Prometheus ingress on |
| `values-qa.yaml` | **dead** — no cluster is named `qa`. Kept, unused. |

`ignoreMissingValueFiles: true` on the ApplicationSet means a newly registered
cluster with no values file yet still renders instead of breaking everything.

> **`values-prod.yaml` carries identity only, deliberately.** The hub has always
> run on `values.yaml` alone, so component toggles here would silently switch
> things on in a live cluster. It previously held env-style toggles
> (external-secrets, kyverno, policy-reporter, falco) that were never applied to
> any cluster; they were dropped rather than enabled behind your back. Change what
> the hub runs in `values.yaml`.

### Metrics across clusters

Each cluster keeps its **own** Prometheus, so a network blip loses no data; the
hub's Grafana just reads them as separate datasources
(`grafana.additionalDataSources` in `app_charts/kube-prometheus-stack/values.yaml`).

Series are told apart by the `cluster` external label, set from `clusterName`.
This matters: the stock dashboards carry **61 `cluster=` selectors**, so every
cluster needs a distinct value or the panels filter wrongly.

> Introducing the label leaves a gap: series stored *before* the change have no
> `cluster` label, so cluster-filtered panels show nothing for them until the
> retention window rolls over.

The datasource URL is plain **http** on purpose — each cluster mints its own lab
CA that the hub does not trust, Traefik here does not force HTTPS, and the traffic
is LAN-internal. Also note Grafana runs in a *pod*, so the spoke hostname has to
resolve through CoreDNS, not the node's `/etc/hosts` — hence
`myLab/04-ArgoCD/manual/coredns-custom.yaml`.

### Adding a cluster — both steps, or neither

Registering a cluster and committing its values file are **one change, not two**:

1. create the registration Secret with `lab.homelab/managed: "true"` and
   `name: <cluster>` (see `myLab` step 13);
2. commit `base-apps/values-<cluster>.yaml` containing **both**
   `clusterName: <cluster>` and `appNameSuffix: "-<cluster>"`.

Do only (1) and the chart refuses to render for that cluster:

```
base-apps: refusing to render for cluster "staging" because clusterName is "prod".
Create base-apps/values-staging.yaml with `clusterName: staging` and
`appNameSuffix: "-staging"` ...
```

That is deliberate. Without the values file the render falls back to the catalog
defaults, where `appNameSuffix` is `""` — so **every** child Application comes out
named exactly as the hub's are, and two root apps fight over the same objects.
The guard at the top of `templates/charts.yaml` compares `renderedForCluster`
(passed by the ApplicationSet) against `clusterName` (from the values file) and
fails rather than let that happen. `ignoreMissingValueFiles` is deliberately
**not** set on the ApplicationSet for the same reason: a missing file should break
one Application loudly, not collide silently.

The hub is the one cluster that keeps `appNameSuffix: ""` — its Applications are
already running under those names, and renaming them would make Argo CD delete
and recreate every component.

> Note the suffix cannot simply be derived from the cluster name by the
> ApplicationSet. Argo CD applies `parameters` as `--set`, which **beats**
> `valueFiles`, so the hub could not override it back to `""` — it would become
> `-prod` and every running Application would be renamed. Hence: suffix in the
> values file, guard to make forgetting it safe.

### If two roots ever do fight

Detect it — any child owned by a root that no longer exists, or counts that do
not add up to one root per cluster:

```bash
kubectl get app -n argocd -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' \
  | cut -d: -f1 | sort | uniq -c
```

Removing the extra root is **not** enough, and this is the part that surprises
people: deleting it leaves the children carrying `tracking-id: <old-root>:...`,
and Argo CD will not take over a resource tracked by another app. The new root
sits `OutOfSync` with a stale `SharedResourceWarning` naming an app that no
longer exists. Rewrite the annotation to the new parent — which is exactly what
Argo CD itself writes:

```bash
kubectl annotate app <child> -n argocd \
  argocd.argoproj.io/tracking-id=<new-root>:argoproj.io/Application:argocd/<child> --overwrite
```

Adoption then completes on the next refresh. And strip the finalizer *before*
deleting any root app, or the delete cascades into pruning everything it owns.

### Scope and risk

- The hub is a single point of failure for **deployments**, not for runtime: a
  spoke keeps serving if the hub dies, it just cannot be changed.
- The ApplicationSet ships `applicationsSync: create-update` and
  `preserveResourcesOnDeletion: true`. Both are load-bearing: without them,
  deleting a cluster's Secret deletes its root app, which cascades into deleting
  everything that cluster runs.
- `tools` is still `{namespace:*, server:*}`, which is the only reason remote
  destinations need no AppProject change. Tightening it means listing each
  cluster's server.

---

## 10. The DNS domain

Every component that exposes a UI gets its hostname from one value:

```
myLab vars/k8s.yml: global_dns_name
        └─► root Application helm parameter `global.dnsName`
                └─► templatedValues ──► each chart's ingress host + TLS SAN
```

Hostnames live in the `templatedValues` block of each catalog entry, because the
five UI charts each use a different ingress schema — `api.host` (Kargo),
`ingress.hostname` (Keycloak), `dashboard.ingress.hosts[]` (Rollouts),
`ui.ingress.hosts[].host` (Policy Reporter), `grafana.ingress.hosts[]` (Grafana).
No uniform block is possible, so each is written out once:

```yaml
charts:
  kargo:
    templatedValues:
      api:
        host: 'kargo.{{ .Values.global.dnsName }}'
```

Nothing is hardcoded in `app_charts/` — `grep -r home.lab base-apps/` returns
only the `global.dnsName` default.

| Component | Host |
|---|---|
| Argo Rollouts dashboard | `rollouts.<domain>` |
| Kargo UI | `kargo.<domain>` |
| Policy Reporter UI | `kyverno.<domain>` |
| Grafana | `grafana.<domain>` |
| Keycloak | `keycloak.<domain>` |

TLS comes from `local-cluster-issuer`, a cert-manager `ca` ClusterIssuer that
`myLab` bootstraps from a lab root CA. Trust that CA once and every host above
is valid. The certificates carry no hardcoded domain, so changing
`global_dns_name` just reissues them.

### `extraValues` vs `templatedValues`

`templatedValues` is rendered through Helm's `tpl`, so it can reference
`{{ .Values.global.dnsName }}`. `extraValues` is passed through verbatim — keep
anything containing literal Go template syntax there (Alertmanager notification
templates, Falco rules, Grafana dashboards), or `tpl` will try to evaluate it
and fail.

---

## 11. Rendering locally

Always render before you push — the root app syncs automatically.

```bash
# the catalog alone
helm template base-apps base-apps -f base-apps/values.yaml

# with an environment overlay
helm template base-apps base-apps -f base-apps/values.yaml -f base-apps/values-dev.yaml

# check a different domain propagates
helm template base-apps base-apps -f base-apps/values.yaml --set global.dnsName=lab.example.com \
  | grep -E 'host|hostname'

# list what each value-set produces
# (written out rather than looped: zsh does not word-split unquoted vars,
#  so building the "-f ..." flags in a variable silently renders nothing)
helm template b base-apps -f base-apps/values.yaml                              | grep -c '^kind: Application'
helm template b base-apps -f base-apps/values.yaml -f base-apps/values-dev.yaml  | grep -c '^kind: Application'
helm template b base-apps -f base-apps/values.yaml -f base-apps/values-qa.yaml   | grep -c '^kind: Application'
helm template b base-apps -f base-apps/values.yaml -f base-apps/values-prod.yaml | grep -c '^kind: Application'
# expect 7, 11, 11, 11

helm lint base-apps -f base-apps/values.yaml
```

Verify an OCI chart reference resolves before adding it:

```bash
helm show chart oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.5
```

---

## 12. Gotchas

**OCI-hosted charts use the bare host — no `oci://` scheme.** Argo CD has two
modes. A bare host plus `chart` means "Helm chart in an OCI registry" and
resolves as `<repoURL>/<chart>:<targetRevision>`. Adding `oci://` switches it to
OCI-artifact mode, where `repoURL` is the *complete* reference and `chart` is
**ignored**, so the chart segment never makes it into the request:

```
failed to resolve revision "1.12.5": cannot get digest for revision 1.12.5:
HEAD "https://ghcr.io/v2/akuity/kargo-charts/manifests/1.12.5": 403 denied
```

Note the missing `/kargo`. ghcr.io answers `403 denied` for a repository that
does not exist, so this looks like an auth failure when it is a path problem.
Verified on Argo CD v3.6.1. Note that Flux is the opposite — its `OCIRepository`
wants the full path *with* the scheme (`oci://ghcr.io/akuity/kargo-charts/kargo`),
which is why `fluxCD/infra/kargo/ocirepository.yaml` looks different.

**Every `charts:` entry needs `app_charts/<name>/values.yaml`, even empty.** The
template always emits that `valueFiles` path and `ignoreMissingValueFiles` is not
set, so a missing file fails manifest generation. Four entries carry no values at
all for exactly this reason — `external-secrets` and `kube-green` are zero-byte,
`kro` and `kyverno` contain only a `---` marker.

**`Healthy` does not mean "working".** Health describes resources already in the
cluster, so a fresh Application that cannot even fetch its chart still reports
`Healthy` — only `SYNC: Unknown` reveals the failure. Always check both:

```bash
kubectl get app -n argocd -o custom-columns=\
NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl get app -n argocd <name> -o jsonpath='{.status.conditions}'
```

**CRD-heavy charts need `serverSideApply: true`** or you hit the annotation size
limit. Already set for `kyverno` and `kube-prometheus-stack`.

**kube-prometheus-stack needs two k3s-specific fixes.** k3s runs the control
plane as a single binary, so there is no `kube-scheduler`,
`kube-controller-manager`, `kube-proxy` or `etcd` Service in `kube-system`. The
chart scrapes all four by default, and the result is four permanently-Down
targets firing `KubeSchedulerDown`, `KubeControllerManagerDown`, `KubeProxyDown`
and `etcdMembersDown` forever — which makes the alerting surface useless on day
one. All four are disabled in `app_charts/kube-prometheus-stack/values.yaml`,
which removes 5 noise alerts and keeps 131 real ones. Separately, the chart's
`prometheusSpec.storageSpec` default is `{}`, meaning **emptyDir** — every pod
restart would discard all history — so it gets an explicit PVC.

**Argo CD's own ServiceMonitors cannot come from the Argo CD chart.** Ansible
installs Argo CD, which then installs kube-prometheus-stack, so the
`monitoring.coreos.com/v1` CRD does not exist at Argo CD install time. The chart
gates its ServiceMonitors on `.Capabilities.APIVersions.Has`, so
`metrics.serviceMonitor.enabled: true` there renders **nothing, silently**. The
Ansible values set only `metrics.enabled: true` (a Service, no CRD needed) and
the ServiceMonitors ship from `declarative/apps/monitoring-extras` in wave 2.
Their selectors are copied verbatim from the chart — worth knowing that three of
the five metrics Services share `app.kubernetes.io/name: argocd-metrics`, so the
`app.kubernetes.io/component` label is what actually disambiguates them.

**Secrets are committed in plaintext.** `app_charts/kargo/values.yaml` holds an
admin password hash and token signing key; `app_charts/keycloak/values.yaml` has
`admin`/`admin`. Fine for a lab, not for anything else — move them to External
Secrets, which is already in the catalog.

**`Chart.yaml` has a name with spaces** (`App of apps standard services`).
`helm template` works, but `helm package` would produce an awkward archive name.
Both charts in this repo also share that name and version `1.8.5`.

---

## 13. The Flux track

`fluxCD/` and `fluxChart/` are a parallel implementation of the same stack with
Flux CD, kept deliberately for comparison. **`myLab` does not use them.**

| | Argo CD (`base-apps/`) | Flux (`fluxCD/`) |
|---|---|---|
| Rendering | Helm chart generates `Application`s | Plain manifests per app |
| Source | multi-source `$values` ref | `HelmRepository` / `OCIRepository` |
| Release | `Application` | `HelmRelease` |
| Enable/disable | `enabled:` in values | comment a line in `infra/kustomization.yaml` |
| Values | `app_charts/<name>/values.yaml` | inlined in each `helmrelease.yaml` |

`fluxCD/` is the hand-written variant and the one wired up:

```
fluxCD/flux/sources.yaml                  GitRepository -> this repo
fluxCD/flux/base-apps-kustomization.yaml  Kustomization -> ./fluxCD/infra
fluxCD/infra/kustomization.yaml           the enable/disable list
fluxCD/infra/<app>/                       helmrepository|ocirepository + helmrelease
```

`fluxChart/` is an earlier experiment: a Helm chart that generates
`HelmRepository` + `HelmRelease` pairs from the same catalog shape, reading
`app_charts/*/values.yaml` with `$.Files.Get` instead of Argo CD's `$values`
ref.

Both Flux directories have **drifted** from `base-apps/` and are not maintained
in step with it:

- older chart versions (Kargo 1.8.9 vs 1.12.5, kro 0.7.0 vs 0.10.0)
- hostnames still hardcoded to `home.lab`; no `global.dnsName`
- no `apps:` section, no `templatedValues`, no environment overlays
- `fluxCD/infra/` carries a `vault` component that the Argo catalog does not

Treat them as a reference for how the same stack looks under Flux, not as a
deployable mirror.
