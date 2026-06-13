# ENVIRONMENT

Versions, regions, names and ARNs. **No secret values appear here or anywhere
else in the repo.**

## Versions

| Tool / component        | Version  | Pinned where                              |
| ----------------------- | -------- | ----------------------------------------- |
| Terraform               | 1.15.6   | `.terraform-version` (tfenv)              |
| AWS provider            | ~> 6.0   | `infra/*/versions.tf` + lock files        |
| Podinfo                 | 6.13.0 (`875ffa943136…`) | `app/Dockerfile`, `pipeline.yml` |
| Go (builder)            | 1.26-alpine, by digest | `app/Dockerfile`            |
| AWS Lambda Web Adapter  | 1.0.1, by digest | `app/Dockerfile`                  |
| Runtime base            | alpine:3.23, by digest (non-root) | `app/Dockerfile` |
| CodeDeploy agent        | latest (host install at boot) | `infra/ec2/user_data.sh.tpl` |

## Region & account

The stack is account-agnostic: it deploys into whatever account the running
AWS credentials belong to. `<account-id>` below is resolved at runtime from
`aws sts get-caller-identity` (Terraform/scripts) or from the
`AWS_ACCOUNT_ID` GitHub variable (CI). No account is hardcoded.

- Region: `eu-north-1` by default (override with `AWS_REGION`; multi-region plan in `docs/SCALING.md`)
- AWS account: `<account-id>` (the caller's own account)
- Environments: `dev`, `prod` — same account, isolated by name prefix
  (`canary-dev-*` / `canary-prod-*`) and separate Terraform state keys.

## Terraform state

- Bucket: `canary-rollout-tfstate-<account-id>-<region>` (versioned, encrypted) —
  created by `scripts/bootstrap.sh`, injected at `init` by `scripts/tf.sh`
- Lock table: `canary-rollout-tf-lock`
- Keys: `global/`, `lambda/<env>/`, `ec2/<env>/`, `observability/` + `terraform.tfstate`

## CI identities (OIDC, no static keys)

The GitHub repo trusted by these roles is the Terraform variable `github_repo`
(set it to the client's `owner/repo`).

| Role | ARN | Trusted GitHub subject |
| ---- | --- | ---------------------- |
| Build | `arn:aws:iam::<account-id>:role/canary-ci-build` | `repo:<github_repo>:ref:refs/heads/main` |
| Deploy | `arn:aws:iam::<account-id>:role/canary-ci-deploy` | `repo:<github_repo>:environment:dev\|prod` |

## Key resources

| Resource | Name |
| -------- | ---- |
| ECR repository | `canary/podinfo` (immutable tags, scan-on-push, KMS) |
| Secret | `/dockyard/SUPER_SECRET_TOKEN` (KMS CMK `alias/canary-rollout`, 30-day rotation) |
| Rotation function | `canary-secret-rotation` |
| SNS alarms topic | `canary-rollout-alarms` |
| Revisions bucket | `canary-rollout-revisions-<account-id>` |
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

The workflows read the target account and region from GitHub **repository
variables** (Settings → Secrets and variables → Actions → Variables) so the
same workflows run in any account with no edits:

| Variable | Example | Used for |
| -------- | ------- | -------- |
| `AWS_ACCOUNT_ID` | `123456789012` | OIDC role ARNs, ECR registry, revisions bucket |
| `AWS_REGION` | `eu-north-1` | region for all CI AWS calls |

Everything else (registry path, repo, podinfo pin) is derived in the workflow
`env:` blocks. GitHub environments `dev` and `prod` gate the deploy jobs;
`prod` requires reviewer approval. No GitHub **secrets** are required.
