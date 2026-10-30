# TraderX Hardening Challenge (workshop game)

Teams each get their own copy of TraderX that runs but breaks six Kyverno
policies. Each policy checks a CCC.K8S control (images pinned by digest,
restricted workloads, resource bounds, governance labels, non-default service
accounts, credentials in Secrets). Teams harden their copy without breaking it,
and a live scoreboard ranks them.

```
facilitator laptop ──ssh -L 8088──▶ jumpbox: game-20-scoreboard.sh ──▶ http://localhost:8088 (projector)
team laptops ──ssh team-NN@jumpbox──▶ kubectl as ServiceAccount team-NN/player ──▶ namespace team-NN
team browsers ──http://<LB_IP>/──▶ edge-proxy-public in team-NN
```

## Before the workshop

1. Build the environment up to step 4 of [the workshop README](../README.md)
   (`10-run-example.sh`). Kyverno must be installed.
2. Set `admin_ssh_source_cidr` in `landing-zone/terraform.tfvars` to the
   venue's public IP range. It controls who can SSH to the jumpbox and reach
   the TraderX load balancers. Then run `terraform apply` and
   `./scripts/05-sync-jumpbox.sh` from the laptop.
3. Don't run `30-deploy-traderx.sh` as well, or delete its `traderx-N`
   namespaces first: the 2-node cluster fits about four TraderX copies in total.
4. On the jumpbox:

   ```bash
   /opt/aks-ccc/game-10-setup.sh                 # 4 teams
   GAME_TEAMS=5 /opt/aks-ccc/game-10-setup.sh    # or another number
   ```

   It prints each team's SSH login, password, load balancer IP and app URL.
   The passwords are kept in `~/ccc-game/teams.tsv` on the jumpbox.
5. Rehearse: log in as a team, fix one Deployment and watch the scoreboard
   change.

## During the game

```bash
./game/25-scoreboard-from-laptop.sh   # laptop, from workshop/aks: opens http://localhost:8088/
```

Hand out one login per team. Each team gets:

- `ssh team-NN@<jumpbox-ip>` with a password; kubectl works in `team-NN` only,
  through the ServiceAccount `player` and the `edit` role;
- `~/traderx.yaml` (the starter), `~/MISSION.md` (rules, policies, hints) and
  `game-status` (pass counts and failing checks with Kyverno's messages);
- `crane` to look up image digests;
- TraderX at `http://<LB_IP>/` from the venue network. `team-NN.<private zone>`
  only resolves inside the VNets, for example from the jumpbox.

Each team's CPU and memory requests share a quota (`GAME_TEAM_CPU`,
`GAME_TEAM_MEMORY`), so one team can't starve the others. Pods without
requests get 25m CPU and 32Mi memory by default.

## Scoring

Scoring is live: [`scoreboard.py`](scoreboard.py) recomputes it every 15
seconds.

- 10 points for each pair of starter Deployment (19) and game policy (6) that
  passes Kyverno's latest result **while that Deployment has a running
  replica**. Crashing or deleting a Deployment loses its points.
- 100 points while `http://team-NN.<zone>/` answers through the load balancer.
- Maximum 1,240. Ties go to the team that reached its score first.

The starter scores 330: the 10 TraderX images are already pinned, 13 of the 19
Deployments have no credential variables, plus the app bonus.

The game policies (`game-*`) are generated from
[`examples/traderx/policies/validating-policies.yaml`](../../../examples/traderx/policies/validating-policies.yaml)
with `validationActions: [Audit, Warn]` and the team namespaces as their scope.
Nothing is blocked; `kubectl apply` prints each violation as a warning, and
Kyverno's PolicyReports feed the scoreboard. The checked-in `traderx-*` policies
(Deny on namespace `traderx`) are unchanged.

The scoreboard also writes `~/ccc-game/scoreboard/scores.json` and
`history.csv` (score per team per refresh) for a recap after the game.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `GAME_TEAMS` | `4` | Number of teams (`team-01`..). |
| `GAME_TEAM_CPU` / `GAME_TEAM_MEMORY` | `1200m` / `5Gi` | Requests quota per team. Four teams use most of what 2 × D4s_v5 has left after system pods. |
| `GAME_TOKEN_HOURS` | `12` | Lifetime of each team's kubectl token. Rerun the setup to issue new ones. |
| `GAME_RESET` | `false` | `true` deletes the team namespaces and gives every team the starter again. |
| `GAME_SCOREBOARD_PORT` / `GAME_REFRESH_SECONDS` | `8088` / `15` | Scoreboard port and refresh interval. |

Rerunning the setup is safe. It keeps each team's namespace, `~/traderx.yaml`
and password. To reset one team, run `kubectl delete namespace team-02`, delete
`/home/team-02/traderx.yaml` and rerun the setup.

**15 attendees:** 4 teams of 3–4 people fit one cluster. For more teams, build
another environment, or scale the node pool and raise the quotas.

## After the game

```bash
/opt/aks-ccc/game-90-teardown.sh   # jumpbox
```

It removes the team namespaces and load balancers, the `game-*` policies and
player RBAC, the `team-NN` users and their password logins. The scoreboard
history stays. Run it before `90-destroy-example.sh`.

## Things to know

- **Not proven solvable:** nobody has yet reached a full score, which means
  hardening every Deployment. Several images run as root by default (the
  TraderX services, nginx, NATS, PostgreSQL), so the restricted policy may need
  `runAsUser` values and writable `emptyDir` mounts. Some images may not run as
  non-root at all. Rehearse, and adjust the hints in [`MISSION.md`](MISSION.md).
- **Password SSH:** team users log in with a password; `azureuser` stays
  key-only. The setup adds a `Match User team-*` block to
  `/etc/ssh/sshd_config`, and teardown removes it. The NSG still limits SSH to
  `admin_ssh_source_cidr`.
- **What teams can touch:** `edit` in their namespace lets a team change its
  `edge-proxy-public` Service and its external-dns hostname annotation, which
  could claim another team's DNS name. The rules ask teams not to. The quota
  allows one load balancer per team.
- **Jumpbox load:** all teams share the 2-vCPU jumpbox, which is fine for
  kubectl. If `crane` and many sessions slow it down, raise `jumpbox_vm_size`
  in `landing-zone/terraform.tfvars`.
