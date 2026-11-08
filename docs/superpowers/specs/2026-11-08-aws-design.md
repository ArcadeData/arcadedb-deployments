# AWS Deployment Templates — Design Spec

**Date:** 2026-11-08
**Status:** Draft (awaiting approval)

---

## Purpose

The `arcadedb-ami` repository builds and publishes the ArcadeDB AMI
(AWS Marketplace) and holds Terraform and CloudFormation templates for
deploying it. That repository stays private, so users have no public examples.
This design adds an `aws/` scenario here with two kinds of example:

1. **Single instance** — a port of the existing templates from `arcadedb-ami`.
2. **HA cluster** — new templates (not a port): a 3-node ArcadeDB Raft cluster
   across three Availability Zones.

Each ships as Terraform and as CloudFormation, so users pick their tool.

### What success looks like

- A user with an AWS account and the public Marketplace AMI can deploy either
  topology with Terraform or CloudFormation by following `aws/` READMEs alone.
- Templates pass static validation in CI on every change (no AWS credentials).
- Nothing in the public repo refers to private-repo internals.

### Non-goals

- Packer/AMI build, Marketplace publishing, the GitHub OIDC role
  (`ci-github-oidc-role.yaml`): publishing tooling, stays private.
- Real AWS deployments in CI (no credentials, cost).
- Auto Scaling groups, multi-region, backups to S3, TLS termination, monitoring.
- Custom VPC creation: the user supplies VPC and subnets.

### Anti-goals

- Templates that only look right: every parameter documented, defaults safe
  (encrypted volumes, IMDSv2, no `0.0.0.0/0` default).
- Clever abstraction. Following the repo's showcase style (readability over
  DRY), no shared modules between single and HA; HA is its own flat template.

## Layout

```
aws/
  README.md                       # overview, topology choice, prerequisites, cost note
  terraform/
    single-instance/              # port: main.tf variables.tf outputs.tf userdata.sh.tftpl terraform.tfvars.example README.md
    ha-cluster/                   # new, same file set
  cloudformation/
    single-instance.yaml          # port
    ha-cluster.yaml               # new
    README.md
.github/workflows/aws.yml         # static validation
```

Root `README.md` gets an `AWS` row in the scenarios table and an `AWS CI`
badge; `all-modules.yml` calls `aws.yml`. (Scenario scripts `start.sh`/`test.sh`
do not apply: these deploy to real AWS and are validated statically.)

## Single instance (port)

Copy from `arcadedb-ami/terraform` and `arcadedb-ami/cloudformation/arcadedb-single-instance.yaml`.
Changes: relocate into the layout above; scrub private references (Packer
names, `ManagedBy: packer-arcadedb-ami`, links into private docs); keep
Marketplace AMI lookup by product code (x86_64 and arm64 codes are in the
existing README; they are public listing identifiers, but this is an assumption
to confirm). Behaviour otherwise unchanged.

## HA cluster (new)

### Topology

- 3 EC2 instances `node-0`, `node-1`, `node-2`, one per subnet/AZ (user passes
  three subnet IDs in distinct AZs).
- Server names must be `<prefix>-<index>` with a 0-based index; this is an
  ArcadeDB Raft requirement, see the `ha-cluster` scenario.
- Same AMI as single instance; same architecture-matching lookup.

### Node discovery: Route 53 private hosted zone

A private hosted zone (default `arcadedb.internal`) attached to the user's VPC
holds one A record per node (`node-0.arcadedb.internal` → private IP). Every
node's `serverList` is the same DNS-name list, so userdata differs only by
node index. Replacing an instance only needs the A record updated.
Requires `enableDnsSupport` and `enableDnsHostnames` on the VPC (documented
prerequisite).

### ArcadeDB configuration (via the existing `ARCADEDB_SETTINGS` override)

```
-Darcadedb.server.name=node-<i>
-Darcadedb.ha.enabled=true
-Darcadedb.ha.serverList=node-0.<zone>:2434:2480,node-1.<zone>:2434:2480,node-2.<zone>:2434:2480
-Darcadedb.ha.replicationFactor=3
-Darcadedb.server.readinessRequiresHA=true
-Darcadedb.server.rootPassword=<shared>
```

Plus the single-instance settings (database/backup dirs, mode, HTTP port, RAM,
plugins, extra opts). Root password: the same value on every node, set the
same way as single instance (users file removal on first boot).

### Networking

- Node security group: 2434 (Raft) from the group itself only; 2480 from
  `allowed_cidr` (default is a private range, never `0.0.0.0/0`); 22 optional.
- Optional internal **Network Load Balancer** (toggle, default on): TCP 2480,
  one target per node, health check `GET /api/v1/ready`. With
  `readinessRequiresHA=true`, only nodes in the cluster take traffic.
  Output: NLB DNS name. This is the call made without an explicit answer from
  the user; flagged for review.

### Common hardening (both topologies)

IMDSv2 required, EBS encrypted gp3, instance type allow-list as in the port,
`volume_size` configurable.

### Outputs

Node private IPs and DNS names, Studio URL (NLB or `node-0`), zone name.

### Validation / CI (`aws.yml`)

Path-filtered on `aws/**`, plus `workflow_call`/`workflow_dispatch` like the
other scenarios. Jobs: `terraform fmt -check` + `init -backend=false` +
`validate` for both Terraform dirs; `cfn-lint` for both templates. Optional
`checkov` is left to the builder. Action pins follow existing workflows.

## Approaches considered

| Approach | Trade-off | Outcome |
|---|---|---|
| Route 53 private zone, 3 instances | one extra resource type; stable names, identical userdata | **chosen** |
| Fixed private IPs | no DNS, but brittle (free IPs, CFN parameters) | rejected |
| Auto Scaling group + dynamic discovery | fights Raft's fixed node index | rejected |

## Left to the builder

- Exact variable names and file split, consistent with the ported templates.
- Whether to add `checkov`/`tfsec` to CI.
- README structure beyond: prerequisites, quick start, variables table,
  cleanup, "validated statically only" note.
- Port-time test of both ported templates against the repo's linters.

## Author's calls (from builder review; change if wrong)

- **DNS names and boot order:** the `ha-cluster` (Docker aliases) and
  `kubernetes` (headless service DNS) scenarios already run Raft with
  name-based `serverList`, so names are supported. A records are created
  by the template as instance resources in the same stack/apply; nodes start
  in parallel and Raft retries peers, so userdata needs no wait loop. The
  "update the record on replacement" claim is softened: replacing a node may
  need a restart of the others, to be documented as unverified until the
  manual deploy checks it.
  CloudFormation ordering: zone → instances → records (records reference
  instance IPs; userdata references only the static names).
- **AMI version:** the AMI ships ArcadeDB 26.10.2, the same version as the
  `ha-cluster` scenario, so the same `-Darcadedb.ha.*` flags apply. The
  existing `ARCADEDB_SETTINGS` override already carries `rootPassword`, and
  the users-file removal runs before first start on each node; each node
  derives the same root user from the same password, so nothing conflicts.
  Verified by the manual deploy.
- **Root password:** a plain sensitive Terraform variable / `NoEcho` CFN
  parameter, as in the single-instance templates. No Secrets Manager or SSM,
  so no instance profile. The README states that it ends up in user data and
  state, as the ported README already does.
- **NLB:** `/api/v1/ready` is unauthenticated (used as the health check in
  `ha-cluster`). Followers are expected to forward writes to the leader, so any node can
  take traffic (to be confirmed by the manual deploy, with a write sent through the NLB). Internal NLB preserves client IPs, so `allowed_cidr` must
  cover the real clients; documented.
- **Ports:** security group also allows 2480 between the nodes themselves
  (peer HTTP), in addition to 2434 and `allowed_cidr`.
- **CloudFormation AMI:** takes an `AmiId` parameter (no product-code lookup
  in CFN), as the source template does; Terraform keeps the data-source lookup.
  README tells users to subscribe to the Marketplace listing first.
- **Networking:** public IPs are off by default (`associate_public_ip`
  toggle); instances need outbound access only if the user installs extras.
  Distinct-AZ check is a Terraform precondition; CFN documents it.
- **Port fidelity:** the port may fix lint findings (`fmt`, `cfn-lint`) but
  keeps parameter names and defaults.

## Live deploy test (second deliverable, in the private `arcadedb-ami` repo)

This public repo has no AWS credentials, so HA is tested for real from
`arcadedb-ami`, which has the accounts and already runs `terraform-test.yml`
and `cloudformation-test.yml` for the single instance.

- **New workflows** `terraform-ha-test.yml` and `cloudformation-ha-test.yml`
  (or one workflow with a matrix), `workflow_dispatch` only at first, with a
  `ref` input (default `main`) naming the `arcadedb-deployments` ref to test.
  A weekly schedule and a run after each AMI release come once stable. No
  per-push trigger (cost, about 10 minutes).
- **Template source:** check out `arcadedb-deployments` at `ref`; no copies
  of the templates in the private repo.
- **Flow:** apply the HA example → wait for `/api/v1/ready` through the NLB →
  smoke tests → destroy in an `if: always()` step, plus a tag-based cleanup
  backstop for leaked resources.
- **Smoke tests** (run from inside the VPC via SSM Run Command on one node,
  so nodes stay private; the test setup adds the needed instance profile):
  1. `GET /api/v1/server?mode=cluster` shows 3 nodes and one leader.
  2. A write sent through the NLB is readable from all 3 nodes (confirms
     follower write forwarding).
  3. Stop the leader instance: a new leader is elected and writes succeed.
- **Requirements on the public templates:** outputs for the NLB DNS name and
  instance IDs, and a `name_prefix` / tags variable so the cleanup backstop
  can find resources.
- **Sequencing:** (1) approve this design; (2) implement and open the public
  PR on `feat/aws`; (3) add the private workflows on an `arcadedb-ami` branch
  pointing at `feat/aws`; (4) merge the public PR once they pass. This
  replaces any manual deploy as the verification of the "to be confirmed"
  items above.
