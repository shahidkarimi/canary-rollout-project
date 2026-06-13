# Prod promotion checklist

The pipeline pauses at the `prod` GitHub environment gate after a green dev
deploy. The approver works through this list **before** clicking *Approve*:

1. **Same digest** — the run summary shows one image digest for build,
   dev-Lambda and dev-EC2. Promotion never rebuilds; reject if digests differ.
2. **Policy gate passed** — the dev deploy log shows `POLICY GATE PASS`
   (cosign keyless signature from this repo's pipeline on `main`).
3. **Dev canary completed cleanly** — both CodeDeploy deployments succeeded
   (no rollback events), smoke + synthetic checks green on both front doors.
4. **Dashboard healthy** — `canary-rollout` dashboard: no dev 5xx spike,
   latency percentiles flat through the canary window, no firing alarms.
5. **No in-flight incident** — alarms topic quiet; no unresolved alerts.
6. **Rollback path clear** — previous prod version/color known good (CodeDeploy
   history), so an automatic rollback would land somewhere safe.

After approval, prod repeats the identical blue/green canary on both targets
with the same digest. If any prod alarm fires during the canary windows,
CodeDeploy rolls back automatically and the run fails — no manual action
needed.
