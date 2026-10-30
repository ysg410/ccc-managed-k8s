# TraderX Hardening Challenge: __TEAM__

Your team runs TraderX in namespace `__TEAM__` on a CCC-hardened AKS cluster.
It works, but it breaks six Kyverno policies that check controls from the FINOS
Common Cloud Controls Kubernetes catalog (CCC.K8S). Harden it **without
breaking it**.

## Scoring (live on the projector)

- 10 points for every Deployment that passes a policy **while it is running**.
  There are 19 Deployments and 6 policies.
- 100 points while TraderX answers at `http://__APP_HOST__/`.
- A crashed or deleted Deployment earns nothing, so roll out changes carefully.
- Ties go to the team that reached its score first.

## Your tools

```bash
cat ~/MISSION.md                      # this file
game-status                           # pass counts per policy and every failing check
game-status edge-proxy                # one Deployment only
kubectl apply -f ~/traderx.yaml       # apply your changes (warnings show what still fails)
kubectl get pods; kubectl describe pod <pod>; kubectl logs <pod>
kubectl rollout status deployment/<name>
kubectl get validatingpolicies         # the six game-* policies (read-only)
kubectl get validatingpolicy game-restricted-workloads -o yaml
crane digest docker.io/library/nginx:1.27-alpine   # look up an image digest
curl -sI http://__APP_HOST__/           # is the app up?
```

`~/traderx.yaml` is your copy of the app. Edit it, apply it and check
`game-status`. You can change everything in your namespace except the
`edge-proxy-public` Service. Your team's CPU and memory requests share a quota of
__CPU__ CPU and __MEMORY__ memory (`kubectl describe resourcequota`).

## The six policies

| Policy | What passes | CCC.K8S |
| --- | --- | --- |
| `game-trusted-images` | Every image is an approved repository pinned by digest only: `repo@sha256:<64 hex>`, no tag. Docker Hub images need the full name, such as `docker.io/library/nginx@sha256:...` | CN04.AR01 |
| `game-restricted-workloads` | `runAsNonRoot: true`, a non-zero `runAsUser`, seccomp `RuntimeDefault` (pod level is fine), and on every container `allowPrivilegeEscalation: false` and `capabilities: {drop: [ALL]}`. No privileged mode, host namespaces or hostPath | CN05.AR01/AR02 |
| `game-resource-bounds` | Every container sets CPU and memory requests **and** limits. CPU 25m ≤ request ≤ limit ≤ 4, memory 32Mi ≤ request ≤ limit ≤ 8Gi | CN13.AR01 |
| `game-governance-labels` | The Deployment **and** its pod template carry `app.kubernetes.io/name` (nonempty), `workshop.finos.org/owner: __TEAM__`, `workshop.finos.org/environment: workshop`, `workshop.finos.org/data-classification: synthetic`, `workshop.finos.org/policy-profile: ccc-k8s-workshop` | CN15.AR01 |
| `game-nondefault-service-account` | `serviceAccountName` set to a ServiceAccount other than `default`. Create it first | CN02 |
| `game-no-inline-credentials` | Variables named like passwords, secrets, tokens or keys (`DATABASE_DBPASS`, `POSTGRES_PASSWORD`, `GF_SECURITY_ADMIN_PASSWORD`) use `valueFrom.secretKeyRef`. Create the Secret first | CN07.AR04 |

## Hints

- Start with the policies that can't break anything: labels, service accounts,
  then resources. Restricted and images need more care.
- Don't change a Deployment's `spec.selector`; Kubernetes won't allow it. Add
  labels next to the existing `app` label instead.
- Several images run as root by default: the TraderX services, nginx, NATS,
  PostgreSQL and blackbox-exporter. Grafana runs as UID 472, Loki, Tempo and the
  OpenTelemetry collector as 10001, and Prometheus as `nobody`, which you must
  set as the number 65534. Root-by-default images may need a `runAsUser` and
  writable `emptyDir` mounts for the paths they write to. Read the logs when a
  pod crashes.
- The database password must stay the same for PostgreSQL and every service
  that connects to it.
- Requests count against your quota. Limits that are too low get containers
  killed (`OOMKilled` in `kubectl describe pod`).
- Stay in your namespace and leave other teams alone.
