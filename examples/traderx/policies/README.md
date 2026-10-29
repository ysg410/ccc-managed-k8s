# TraderX workshop validating policies

Six facilitator-owned Kyverno CEL `ValidatingPolicy` resources, adapted from
[Kyverno best-practices-vpol](https://github.com/kyverno/policies/tree/main/best-practices-vpol)
and the [CCC Kubernetes catalog](https://github.com/finos/common-cloud-controls/blob/main/catalogs/orchestration/k8s/controls.yaml).
They validate only the `traderx` namespace, start in **Deny**, and never mutate
workloads. No Azure resources are created by applying this bundle.

| Policy | Checks | CCC requirement |
| --- | --- | --- |
| `traderx-trusted-images` | Exact approved repositories and SHA-256 digests | CN04.AR01 |
| `traderx-restricted-workloads` | No privileged/host access; non-root, RuntimeDefault, no escalation, drop ALL, add none | CN05.AR01/AR02 |
| `traderx-resource-bounds` | CPU/memory requests AND limits, positive bounds and request <= limit | CN13.AR01 |
| `traderx-governance-labels` | Approved governance labels on Namespace, workload and template metadata | Kubernetes portion of CN15.AR01 |
| `traderx-nondefault-service-account` | Explicit, nonempty serviceAccountName other than default | Supporting CN02 least-privilege guardrail (no exact AR) |
| `traderx-no-inline-credentials` | Credential-named environment variables must use secretKeyRef | Plain-environment-variable portion of CN07.AR04 |

All IDs have prefix `CCC.K8S.`. These are selected requirement checks, not full
control compliance or a production security baseline.

## Prerequisites and installation

Use Kyverno **1.17.0 or later** with the `policies.kyverno.io/v1` API, selecting a
supported release compatible with your AKS Kubernetes version. A Kubernetes
native `ValidatingAdmissionPolicy` installation alone is not sufficient.
See [Kyverno releases](https://kyverno.io/docs/installation/releases/) and
[AKS installation notes](https://kyverno.io/docs/installation/platform-notes/#notes-for-aks-users).
Install Kyverno separately in its own namespace with its reports controller
enabled. A non-production single-replica installation is suitable for rehearsal,
not proof of admission availability. Account for its additional resource usage.

From the repository root, after confirming the intended test-cluster context:

```bash
kubectl config current-context
kubectl get namespace traderx --show-labels
kubectl get crd validatingpolicies.policies.kyverno.io
kubectl explain validatingpolicy --api-version=policies.kyverno.io/v1

kubectl apply --dry-run=server -f examples/traderx/policies/validating-policies.yaml
kubectl apply -f examples/traderx/policies/validating-policies.yaml

kubectl get validatingpolicies.policies.kyverno.io
kubectl get validatingpolicies.policies.kyverno.io traderx-trusted-images -o yaml
kubectl get policyreports.wgpolicyk8s.io -n traderx
```

Check policy readiness/status and reports for evaluation errors. Background
reports are asynchronous. Noncompliant create/update requests are denied once
the policies are active; existing Pods are not evicted when a policy is installed.

## Scope and controller coverage

Namespace selection uses the immutable `kubernetes.io/metadata.name=traderx`
label, not a participant-editable opt-in label. These cluster-scoped policies
do not apply workshop constraints to `kube-system`, Kyverno or other namespaces.
To add team namespaces, change **each policy's** namespace selector to a
`matchExpressions`/`In` list of exact namespace names.

Pods, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs and CronJobs are
matched explicitly and their Pod specifications are normalized in CEL; this
does not depend on controller autogeneration. Image/security/credential policies also
match `pods/ephemeralcontainers`. Resource declarations deliberately exclude
ephemeral containers, because Kubernetes forbids requests/limits on them.
Legacy ReplicationControllers and custom workload controllers are not directly
matched; resulting Pods remain covered, but their parent creation is not gated.
No DELETE, CONNECT, exec or scale-subresource authorization is provided here.

For labels, require metadata on the resource and its Pod template; CronJobs
also require metadata on the Job template. Preserve existing `app` labels and
selectors. Do not change an immutable Deployment selector merely to add labels.

## Workshop choices to review

- The image allowlist contains the demo's ten GHCR and nine infrastructure
  repositories. Docker Hub images must use explicit `docker.io/` names, including
  `docker.io/library/` for PostgreSQL, NGINX and NATS. Participants resolve actual
  digests; a syntactically valid digest does not establish existence, signature,
  provenance or vulnerability status. Signatures/CVE admission (CN04.AR02/03)
  are not implemented.
- Resource bounds are **illustrative workshop guardrails**, not measured app
  sizing: CPU request >= 25m, memory request >= 32Mi, requests <= limits, CPU
  limit <= 4, memory limit <= 8Gi. These do not promise that a container fits a
  particular node or that the whole namespace fits the cluster. Review them
  after measuring startup and trading load; add ResourceQuota separately.
- Label values: owner is `facilitators` or `team-01` through `team-05`;
  environment is `workshop`; data classification is `synthetic`; policy profile
  is `ccc-k8s-workshop`. Each uses the `workshop.finos.org/` key prefix. Also
  require nonempty `app.kubernetes.io/name`. These are an example organization
  standard, not label names prescribed by CCC. This does not enforce owner
  identity, immutable labels, or external audit records (CN15.AR02).
- Restricted workloads must be Linux. Pod-level non-root/seccomp settings can
  be inherited; unsafe container overrides are rejected. All hostPath volumes
  are forbidden, which is stricter than permitting controlled exceptions.
  `readOnlyRootFilesystem` is not required. Some original images/startup paths
  need rebuilding or writable mounts to run non-root; successful admission is
  not proof the application starts or trades correctly.
- Workloads must explicitly set `serviceAccountName` to a nonempty name other
  than `default`. Create the dedicated ServiceAccounts separately and grant
  only needed permissions. This rule does not check account existence or RBAC,
  require unique accounts per workload, or disable automatic token mounting.
- Credential environment variables must use `valueFrom.secretKeyRef` in regular,
  init and ephemeral containers. Name matching is case-insensitive and looks for
  underscore-delimited segments: `password`, `passwd`, `pass`, `dbpass`, `secret`,
  `token`, `apikey`/`api_key`, `accesskey`/`access_key`, `privatekey`/`private_key`,
  and `clientsecret`/`client_secret`. This includes TraderX's `DATABASE_DBPASS`,
  `POSTGRES_PASSWORD` and `GF_SECURITY_ADMIN_PASSWORD`. Literal values (even
  empty ones) and ConfigMap references for these names are rejected. Ordinary
  literal settings such as ports and hostnames, and `envFrom.secretRef`, remain
  allowed. This is a name-based guardrail, not secret scanning: it does not
  inspect `envFrom` ConfigMaps, command arguments, mounted files, connection
  strings or credentials hidden under unrelated variable names. Secret
  creation, encryption, access control and rotation remain separate concerns.

## Enforcement and temporary audit mode

All six policies enforce Deny on installation. If a facilitator needs to
temporarily allow requests while diagnosing a mission, switch the selected
policy to Audit. This is a live cluster change:

```bash
kubectl patch validatingpolicies.policies.kyverno.io traderx-trusted-images \
  --type=merge -p '{"spec":{"validationActions":["Audit"]}}'
```

Use the other names from the table as needed. Restore enforcement:

```bash
kubectl patch validatingpolicies.policies.kyverno.io traderx-trusted-images \
  --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
```

Reapplying the checked-in YAML also restores all six policies to Deny.
`failurePolicy: Fail` is intentional, but inspect actual webhook settings and
availability; these files alone do not establish all CN11 requirements.
Keep policy editing/deletion and exceptions restricted to facilitators.

Do not restart all existing workloads as soon as Deny is enabled: noncompliant
replacement Pods will be blocked. First dry-run repaired Deployment manifests
against the server, roll out a selected component, test the trading flow, then
submit negative variants and confirm the intended policy denies them.

## Tests and limits

With the Kyverno 1.17+ CLI:

```bash
kyverno test examples/traderx/policies/tests
kyverno apply examples/traderx/policies/validating-policies.yaml \
  --resource examples/traderx/traderx-aks-demo.yaml --detailed-results
```

The second command intentionally reports failures against the starter manifest.
The test fixtures use fake digests; **do not deploy them**. Offline tests cover
policy evaluation, not live webhook invocation, namespace isolation, rollout
compatibility or actual image contents. Verify positive and negative admission
on AKS separately before the workshop.

Not included: default-deny/allow NetworkPolicies (CN06), full secret protection and
authorization (CN07/CN02), ResourceQuota/LimitRange (CN13.AR02), external audit
retention (CN14), system-namespace policies, and policy-administrator RBAC.
Those require separate resources/configuration and cannot be replaced by these
six validating policies. Service exposure restrictions are intentionally not
included: `edge-proxy-public` may remain a public LoadBalancer for UI access.
