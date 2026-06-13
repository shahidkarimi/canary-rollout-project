# Scalability design note

## Implemented improvement: provisioned concurrency on the prod Lambda alias

**What**: `provisioned_concurrency = 2` on `canary-prod-podinfo:live`
(`infra/lambda`, prod tfvars only).

**Why this one**: the Lambda target's only structural latency weakness is the
cold start — a container-image function (podinfo + Lambda Web Adapter) pays
image pull + runtime init + adapter readiness on every new sandbox. Provisioned
concurrency removes that class of latency entirely for the provisioned
capacity, costs cents at this scale, touches no release machinery (the alias
is still the CodeDeploy traffic-shift unit), and its impact is directly
measurable — which the other two options can't claim at demo traffic levels:
target-tracking on a fleet pinned to exactly 2 instances by the spec is
contradictory, and a third environment ring multiplies infrastructure rather
than improving a measured property.

**Measurement** (`scripts/measure-coldstart.sh`, results recorded after the
prod runs):

| Configuration | Cold starts in burst | Init p50 | Init p99 | e2e p99 |
| ------------- | -------------------- | -------- | -------- | ------- |
| PC disabled   | _measured post-deploy_ | _ms_   | _ms_     | _ms_    |
| PC = 2        | 0 expected             | n/a    | n/a      | _ms_    |

Method: concurrent burst of 5 at the `live` alias right after a deploy (fresh
version ⇒ guaranteed cold paths without PC), then CloudWatch Logs Insights
over `REPORT` lines (`@initDuration` count + percentiles). With PC enabled the
same burst shows zero `@initDuration` samples on the provisioned environments
and `ProvisionedConcurrencyInvocations > 0`.

**Trade-offs**: ~$0.005/h per provisioned GB-s slot while enabled; capacity
above PC still cold-starts (acceptable: canary + smoke traffic fits within 2).
PC applies to the version the alias points at — during a CodeDeploy canary the
new version warms only after promotion, so the first post-shift requests on
the new version may still cold-start. Mitigation if needed: pre-traffic hook
that warms the target version before the shift.

## Multi-region active/active plan

Target shape: two regions (eu-north-1 + eu-west-1), each running the full
per-env stack (Lambda+API GW, EC2/ALB), fronted by Route 53.

- **Routing**: Route 53 weighted records (active/active) with health checks
  against both regional front doors per target; failover policy as the
  degenerate case (100/0). Weighted is preferred: it keeps both regions
  continuously exercised — a cold standby that has never taken traffic is a
  rollback risk, not a safety net. Latency-based routing once real users exist.
- **Artifacts**: ECR cross-region replication (built-in rule) from the build
  region; deploys in each region reference the same digest, signatures travel
  with the image so the cosign policy gate works identically. The pipeline
  fans out the deploy stage per region after one build.
- **State & release flow**: Terraform state keys gain a region dimension
  (`ec2/<env>/<region>/`). Canary per region sequentially (region A canary →
  promote → region B), so a bad release can never take both regions at once.
- **Environment isolation (accounts)**: move dev and prod into separate AWS
  accounts under AWS Organizations (prod OU with SCPs: deny non-OIDC
  principals on deploy paths, deny disabling CloudTrail/data-protection).
  CI keeps one role per account; the OIDC trust adds the account-specific
  environment claim. This kills the entire class of "dev pipeline touches
  prod resource" bugs that name-prefix isolation only discourages.
- **Data**: podinfo is stateless — the hard multi-region problems (data
  replication, consistency) don't apply here; secrets replicate via Secrets
  Manager multi-region replicas with per-region KMS CMKs and rotation in the
  primary.
- **Risks & costs**: ~2× runtime cost (4 EC2 hosts, 2 ALBs, doubled PC) plus
  Route 53 health checks (~$1.50/mo); cross-region ECR transfer pennies per
  release. Main risks: config drift between regions (mitigate: same modules,
  region only as a variable), alarm fan-out duplication (route both regions
  into one alarm topic/dashboard), and split-brain canary state — the SSM
  active-color parameter is regional by design, so each region's CodeDeploy
  acts on its own state.
