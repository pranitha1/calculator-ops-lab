# v2 — RDS backend + backup validation

Goal: practice provisioning RDS, connecting an app to it securely via SSM Parameter
Store, then doing the backup/DR operations the JD calls out — snapshot creation,
backup validation, and disk sizing.

This is the first version using **Terraform**, so infra is defined as code from
here on. v1 stays manual on purpose (console muscle memory); v2 onward is
code-managed (repeatability + the IaC skill most ops roles eventually want too).

## What this provisions
- RDS Postgres (`db.t3.micro`, 20GB, free-tier eligible), **not publicly accessible**
- A security group that only allows Postgres (5432) from the `calculator-v1-sg` instance
- DB credentials stored in SSM Parameter Store (`/calculator/db_*`, password as SecureString) — the app fetches them at startup instead of hardcoding secrets
- An SNS topic `ops-lab-alerts` (separate from the billing alerts topic) + a CloudWatch alarm on RDS free storage

## Step 1 — Review and apply

```bash
terraform init
terraform plan
```

Review the plan with me before applying — RDS is a bigger/longer-lived resource
than what we've created so far, worth a deliberate look. Then:

```bash
terraform apply
```

Confirm SNS email subscription (check ypranitha1@gmail.com again) once applied.

## Step 2 — Deploy the updated app

Once RDS is up, tell me and I'll push [`deploy-app.sh`](deploy-app.sh) to the
EC2 instance via SSM run-command — it installs `boto3`/`psycopg2-binary`,
replaces `app.py` with the DB-backed version, and restarts the service.

## Step 3 — Backup validation practice (do this yourself, console or CLI)

1. **Manual snapshot**: RDS console → `calculator-v2-db` → Actions → Take snapshot
2. **Validate it exists and is available**: `aws rds describe-db-snapshots --db-instance-identifier calculator-v2-db`
3. **Check automated backup window/retention**: RDS console → Maintenance & backups tab
4. **Disk sizing drill**: RDS console → Modify → increase allocated storage from 20GB → 25GB, apply immediately, watch the modification event stream
5. (Optional, more advanced) Restore the manual snapshot to a new instance `calculator-v2-db-restore-test` to actually prove the backup works — then delete the restored copy

## Step 4 — Verify end to end
Hit `/calculate` a few times, then `/history` to confirm rows are persisted in RDS.
