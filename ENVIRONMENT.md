# ENVIRONMENT

Versions, regions, names and ARNs. **No secret values appear here or anywhere
else in the repo.**

## Versions

| Tool / component        | Version  | Pinned where                              |
| ----------------------- | -------- | ----------------------------------------- |
| Terraform               | 1.15.6   | `.terraform-version` (tfenv)              |
| AWS provider            | ~> 6.0   | `infra/*/versions.tf` + lock files        |
| Podinfo                 | 6.13.0 (`1ec15a1a349f…`) | `app/Dockerfile`, `pipeline.yml` |
| Go (builder)            | 1.26-alpine, by digest | `app/Dockerfile`            |
| AWS Lambda Web Adapter  | 1.0.1, by digest | `app/Dockerfile`                  |
| Runtime base            | distroless/static-debian12:nonroot, by digest | `app/Dockerfile` |
| CodeDeploy agent        | latest (host install at boot) | `infra/ec2/user_data.sh.tpl` |

## Region & account

- Region: `us-east-1` (single region; multi-region plan in `docs/SCALING.md`)
- AWS account: `767911972289`
- Environments: `dev`, `prod` — same account, isolated by name prefix
  (`canary-dev-*` / `canary-prod-*`) and separate Terraform state keys.

## Terraform state

- Bucket: `canary-rollout-tfstate-767911972289-us-east-1` (versioned, encrypted)
- Lock table: `canary-rollout-tf-lock`
- Keys: `global/`, `lambda/<env>/`, `ec2/<env>/`, `observability/` + `terraform.tfstate`

## CI identities (OIDC, no static keys)

| Role | ARN | Trusted GitHub subject |
| ---- | --- | ---------------------- |
| Build | `arn:aws:iam::767911972289:role/canary-ci-build` | `repo:shahidkarimi/canary-rollout-project:ref:refs/heads/main` |
| Deploy | `arn:aws:iam::767911972289:role/canary-ci-deploy` | `repo:shahidkarimi/canary-rollout-project:environment:dev\|prod` |

## Key resources

| Resource | Name |
| -------- | ---- |
| ECR repository | `canary/podinfo` (immutable tags, scan-on-push, KMS) |
| Secret | `/dockyard/SUPER_SECRET_TOKEN` (KMS CMK `alias/canary-rollout`, 30-day rotation) |
| Rotation function | `canary-secret-rotation` |
| SNS alarms topic | `canary-rollout-alarms` |
| Revisions bucket | `canary-rollout-revisions-767911972289` |
| Dashboard | `canary-rollout` |
| Log redaction | account-level CloudWatch Logs data protection policy `canary-redact-secret-token` (masks `dkyd_[A-Za-z0-9]{32}`) |

### Per environment (`<env>` = dev | prod)

| Resource | Name |
| -------- | ---- |
| Lambda function / alias | `canary-<env>-podinfo` / `live` |
| API Gateway HTTP API | `canary-<env>-podinfo` |
| CodeDeploy (Lambda) | app `canary-<env>-lambda`, group `canary-<env>-lambda-dg` |
| ALB | `canary-<env>-alb` (HTTPS 443, self-signed ACM cert; 80 redirects) |
| Target groups | `canary-<env>-blue` (:9898) / `canary-<env>-green` (:9899) |
| ASG | `canary-<env>-asg` (exactly 2 × t3.micro, AL2023, IMDSv2) |
| CodeDeploy (EC2) | app `canary-<env>-ec2`, group `canary-<env>-ec2-dg` |
| Deploy state | SSM `/canary/<env>/ec2/active-color`, `/canary/<env>/ec2/active-image` |
| Log groups | `/aws/lambda/canary-<env>-podinfo`, `/aws/apigw/canary-<env>-podinfo`, `/canary/<env>/ec2/docker` |

## Pipeline variables

All non-secret and defined in the workflow `env:` blocks (account id, region,
registry, repo, podinfo pin). GitHub environments `dev` and `prod` gate the
deploy jobs; `prod` requires reviewer approval. No GitHub secrets are required.
