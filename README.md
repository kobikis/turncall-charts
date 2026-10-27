# TurnCall Charts

One Helm chart, `charts/turncall`, for everything TurnCall runs on Kubernetes:

| Part | Switch | Default |
|---|---|---|
| TurnCall: the API, the eval worker, the campaign worker | always | on |
| Asterisk's ARI edge (one pod) | `asteriskEdge.enabled` | off |
| Postgres (pgvector) and Redis in the cluster | `postgresql.enabled`, `redis.enabled` | off — bring your own |
| Files on a volume instead of S3 | `localStorage.enabled` | off |
| The builder: builder-api, the console, each agent's backend | `builder.enabled` | off |

The code lives in [turncall](https://github.com/kobikis/turncall),
[turncall-builder-api](https://github.com/kobikis/turncall-builder-api) and
[turncall-builder-web](https://github.com/kobikis/turncall-builder-web).

## Published on ghcr.io

| What | Where | Tags |
|---|---|---|
| This chart | `oci://ghcr.io/kobikis/charts/turncall` | each release (`v0.2.0` here → `0.2.0`) |
| TurnCall | `ghcr.io/kobikis/turncall` | releases (`2.1.0`), `main`, `sha-<commit>`; linux/amd64 |
| builder-api | `ghcr.io/kobikis/turncall-builder-api` | releases (`1.0.0`), `main`, `sha-<commit>`; amd64 + arm64 |
| Agent Backend runtime | `ghcr.io/kobikis/turncall-agent-runtime` | as builder-api |
| The console | `ghcr.io/kobikis/turncall-builder-web` | releases, `main`, `sha-<commit>`; amd64 + arm64 |

A release tag in a repo publishes its image (`:1.2.3`, `:1.2`, `:latest`); a
merge to `main` publishes `:main` and `:sha-<commit>`. The packages are
private, like the repos: log in to pull the chart, and give the cluster a
login for the images — a GitHub token with `read:packages`:

```bash
echo "$TOKEN" | helm registry login ghcr.io --username <github user> --password-stdin
kubectl -n turncall create secret docker-registry ghcr --docker-server=ghcr.io \
  --docker-username=<github user> --docker-password="$TOKEN"

helm install turncall oci://ghcr.io/kobikis/charts/turncall --version 0.2.0 -n turncall \
  --set 'imagePullSecrets[0].name=ghcr' -f my-values.yaml
```

The chart's defaults pull TurnCall's `2.1.0` (the first release with the
in-cluster call-init the builder needs) and the builder's `1.0.0`. Pin
TurnCall's `image.tag` in production. `values-local.yaml` and
`values-production.yaml` are in this repo (`helm pull … --untar` has them
too).

## On a laptop: everything

`values-local.yaml` is the docker compose stacks on Docker Desktop's Kubernetes
(or kind, minikube): TurnCall with its own Postgres and Redis, files on a
volume, and the builder. Dev secrets, one pod per data store — not for
production.

It runs local image tags, built from the three repos — on Apple Silicon this
also avoids running TurnCall's amd64-only image emulated. To use the
published images instead, drop the `image` overrides and add a ghcr login
(above).

```bash
docker build -t turncall:dev ../turncall
docker build -t turncall-builder-api:dev ../turncall-builder-api
docker build -t turncall-agent-runtime:dev ../turncall-builder-api/agent-runtime
docker build -t turncall-builder-web:dev ../turncall-builder-web
```

Your keys go in a file of your own:

```yaml
# my-keys.yaml
publicBaseUrl: https://<name>.ngrok-free.dev   # ngrok's URL, for phone numbers; see below
secretEnv:
  OPENAI_API_KEY: sk-...
  DEEPGRAM_API_KEY: ...
builder:
  secretEnv:
    ANTHROPIC_API_KEY: sk-ant-...
```

```bash
helm install turncall charts/turncall -n turncall --create-namespace \
  -f charts/turncall/values-local.yaml -f my-keys.yaml

kubectl -n turncall exec deploy/turncall-builder-api -- python -m scripts.seed_guest
kubectl -n turncall port-forward svc/turncall-builder-web 5173:80   # http://localhost:5173, guest@turncall.local / guest
```

- **Phone numbers** need `publicBaseUrl`: a public https URL that reaches
  TurnCall's API. On a laptop, `kubectl -n turncall port-forward svc/turncall
  8090:80` with `ngrok http 8090` in front. Without it a number is saved but
  not configured at Twilio/Telnyx.
- **Changing values or the chart:** `helm upgrade turncall charts/turncall -n
  turncall --reset-then-reuse-values` (the chart's current defaults plus what
  you installed with). `--reuse-values` alone keeps the old defaults too.
- **A rebuilt image** under the same tag: `kubectl -n turncall rollout restart
  deploy`. `values-local.yaml` sets `pullPolicy: Always`, and Docker Desktop's
  cluster pulls local tags from the Docker engine. On kind or minikube, where
  images are loaded onto the nodes, set `IfNotPresent`.
- **Uninstall** keeps the volumes (the database, the generated repos, files);
  `kubectl delete namespace turncall` removes them too.
- **TurnCall alone:** `--set builder.enabled=false`.
- **Coming from turncall-builder-api's `turncall-stack` chart** (same release
  name): the builder's Deployments carry a different selector label here, which
  Kubernetes will not change in place. Delete them first — `kubectl -n turncall
  delete deploy turncall-builder-api turncall-builder-web` — then upgrade with
  this chart and your values reshaped: `turncall.*` moves to the top level and
  `global.publicBaseUrl` becomes `publicBaseUrl`. Volumes, data and running
  Agent Backends are untouched.

## In production

`values-production.yaml` is a starting point to copy: your Postgres (with the
`vector` extension) and Redis, S3, secrets in Secrets you manage, pinned
images from your registry, and Ingresses with TLS — TurnCall's with
WebSocket timeouts as long as a call, the builder's console with buffering off
for streamed turns. Agent Backends run in a namespace of their own
(`builder.agentNamespace`), away from TurnCall's Secret. Its header lists the
Secrets to create. Replace every `example.com` and placeholder.

What the chart sizes for you, and why, is in TurnCall's Kubernetes guide
(`docs/guides/kubernetes.mdx`): the API's grace period from your longest call,
autoscaling on live calls per pod, the single Asterisk edge.

## How the parts connect

- The builder talks to this release's TurnCall Service, and reads TurnCall's
  `PLATFORM_API_KEY` from TurnCall's Secret — one value, never two.
- With `postgresql.enabled` the builder's database is `builder` on that
  Postgres, created on first start.
- builder-api creates each agent's backend as a Deployment (named for the
  agent) and a Service in `builder.agentNamespace`, holding a Role over just
  those kinds of object there. `imagePullSecrets` reach those pods too.
- With the bundled Postgres, TurnCall's API migrates in an init container and
  the workers wait for it; with your own database, a hook Job migrates before
  any pod starts.

## Contributing

Every commit is signed off (`git commit -s`); CI's `dco` job checks. CI lints
and renders the chart with every values file.

**Releasing the chart:** bump `version` in `charts/turncall/Chart.yaml` in a
PR, merge it, then tag that version: `gh release create v0.3.0
--generate-notes`. The tag publishes the chart; it fails if the tag and
`Chart.yaml` disagree.
