# CLAUDE.md

Canary rollout of one signed Podinfo image to two runtimes — Lambda (API GW) and
EC2/Docker (ALB) — across `dev` and `prod`. CodeDeploy drives both canaries;
CloudWatch alarms auto-rollback. See `README.md` for the full design.

## Stack
- Terraform **1.15.6** (pinned in `.terraform-version`), region **eu-north-1**.
- Remote state in S3 `canary-rollout-tfstate-<account>-<region>` + DynamoDB lock
  `canary-rollout-tf-lock`. Derived from the caller's account — no per-account edits.
- AWS CLI (admin), `gh` (authenticated), `tfenv`.

## Terraform: always use the wrapper
```
scripts/tf.sh <global|lambda|ec2|observability> <dev|prod|-> <plan|apply|destroy ...>
```
It handles `init`, backend config, per-env state keys, and `-var env=`. Never run
`terraform` directly in `infra/*`. Use `-` as the env for `global`/`observability`.

Apply order (deps): `bootstrap.sh` → `global` → `ec2 dev` → first image in ECR →
`lambda dev` → `ec2 prod` → `lambda prod` → `observability`. `lambda` needs ≥1 ECR image.

## Gotchas (learned the hard way)
- **`provisioned_concurrency` must be 0 on prod Lambda** — this account's new-account
  concurrency cap (10) blocks it. README's `=2` will fail apply until the cap is raised.
- **`git push` triggers the pipeline only if `main` has new commits.** When already in
  sync, trigger with `gh workflow run pipeline` instead.
- Pipeline uses `concurrency: group: pipeline` (no cancel) — a new run queues behind
  any in-flight one.
- Prod deploy stops at the `prod` GitHub environment's **required-reviewer gate** — a
  deliberate human approval; do not auto-approve.
- Listener weights / alias versions / function image carry `ignore_changes`; `apply`
  stays idempotent mid-release and must not revert traffic.

## Layout
- `app/` — Dockerfile (podinfo + Lambda Web Adapter + `secret-extension/` Go fingerprint ext).
- `infra/{global,lambda,ec2,observability}/` — Terraform stacks.
- `.github/workflows/` — `pipeline.yml` (build+orchestrate), `deploy.yml` (reusable per-env).
- `scripts/` — `bootstrap.sh`, `tf.sh`, `teardown.sh`, `smoke.sh`, `rotate-and-verify.sh`,
  `measure-coldstart.sh`, `codedeploy/` (appspec + hooks).
- `docs/` — diagram, SCALING.md, PROMOTION_CHECKLIST.md.

## Teardown
`scripts/teardown.sh` (reverse order, idempotent); `--all` also drops the state backend.
