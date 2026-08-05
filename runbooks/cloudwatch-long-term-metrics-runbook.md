# Runbook: Long-Term CloudWatch Metrics (Audit & Capacity Planning)

Reference only — not provisioned in the lab (Kinesis Data Firehose has no
free tier, so this stays a written walkthrough rather than a built resource).
Maps to the JD's "operational reporting" and "backup validation" language —
audits and capacity planning both need history CloudWatch doesn't keep forever.

## Why this exists

CloudWatch's metric retention is tiered, and resolution degrades **before**
data disappears:
- 1-minute datapoints: kept 15 days
- 5-minute datapoints (auto-aggregated): kept 63 days
- 1-hour datapoints (further aggregated): kept 455 days (~15 months)
- After 455 days: **gone permanently**, at any resolution

Two consequences that matter operationally:
1. If you need last year's exact per-minute CPU graph for an incident review, it's already gone — you only ever had 1-hour granularity by day 64.
2. If you need *any* granularity older than ~15 months (annual audits, year-over-year capacity planning), you must have exported it before that cliff — there is no "restore from AWS" option after it expires.

## Part A — Capture everything going forward (CloudWatch Metric Streams)

**Key limitation to say out loud in an interview: this does not backfill.**
It only streams new datapoints from the moment it's turned on.

### Console steps
1. **S3 bucket first** (destination): create one, block all public access, enable default encryption (SSE-S3 or SSE-KMS), and add a **lifecycle rule** transitioning objects to S3 Glacier (or Glacier Instant Retrieval) after ~90 days — this is the "prod grade" cost-control move: raw metric exports are cheap to store cold, expensive to keep in S3 Standard for years.
2. **IAM role for Firehose** — least privilege, not admin: a policy scoped to exactly `s3:PutObject` / `s3:PutObjectAcl` on that one bucket's ARN, nothing broader.
3. **Kinesis Data Firehose console → Create delivery stream**:
   - Source: **Direct PUT**
   - Destination: **S3**, pick the bucket from step 1
   - IAM role: the one from step 2
4. **IAM role for the metric stream itself** — a second least-privilege role, scoped to `firehose:PutRecord` / `PutRecordBatch` on that one specific Firehose stream's ARN only.
5. **CloudWatch console → Metric streams → Create metric stream**:
   - Scope: filter to specific namespaces (`AWS/EC2`, `AWS/RDS`, `AWS/ApplicationELB`, your custom namespace) rather than "All metrics" — this is the cost lever, since Firehose bills per GB ingested
   - Output format: JSON
   - Destination: the Firehose stream from step 3
   - IAM role: the one from step 4
   - Create

### Terraform equivalent (structure only)
```hcl
resource "aws_s3_bucket" "metrics_archive" { ... }
resource "aws_s3_bucket_lifecycle_configuration" "metrics_archive" {
  rule {
    transition { days = 90; storage_class = "GLACIER" }
  }
}

resource "aws_iam_role" "firehose" { ... }              # scoped to this bucket only
resource "aws_kinesis_firehose_delivery_stream" "metrics" {
  destination = "extended_s3"
  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.metrics_archive.arn
  }
}

resource "aws_iam_role" "metric_stream" { ... }          # scoped to this firehose stream only
resource "aws_cloudwatch_metric_stream" "main" {
  role_arn      = aws_iam_role.metric_stream.arn
  firehose_arn  = aws_kinesis_firehose_delivery_stream.metrics.arn
  output_format = "json"
  include_filter {
    namespace = "AWS/EC2"
  }
  include_filter {
    namespace = "AWS/RDS"
  }
}
```

## Part B — Preserve history that already exists (before it ages out)

Metric Streams doesn't help with data you *already have* sitting in the
15-month window. For that, you script a batch export using `GetMetricData`
(bulk/efficient) rather than the older per-metric `GetMetricStatistics`:

```bash
aws cloudwatch get-metric-data \
  --metric-data-queries '[{"Id":"cpu","MetricStat":{"Metric":{"Namespace":"AWS/EC2","MetricName":"CPUUtilization","Dimensions":[{"Name":"AutoScalingGroupName","Value":"my-asg"}]},"Period":3600,"Stat":"Average"}}]' \
  --start-time 2025-05-01T00:00:00Z \
  --end-time 2026-08-01T00:00:00Z \
  --region us-east-1
```

Wrap this in a Lambda (least-privilege execution role: `cloudwatch:GetMetricData`
read-only + `s3:PutObject` scoped to the archive bucket), triggered monthly by
an **EventBridge Scheduler** rule — never wait until data is close to the
15-month cliff to start archiving it.

## Part C — Using the archive for actual capacity reports

Once data is landing in S3 (either path), query it with **Athena** (define a
table over the S3 prefix, partitioned by date) rather than pulling it back
into CloudWatch — this is what turns "we have an export" into an actual
capacity-planning report an interviewer means when they say "have you *done*
this, not just read about it."

## What separates "read the docs" from "done this," for interview purposes

1. Say explicitly that **resolution degrades before deletion** — most people only remember "15 months," not the tiering.
2. Say explicitly that **Metric Streams doesn't backfill** — a very common wrong assumption.
3. Mention **least-privilege IAM roles per hop** (metric stream → Firehose → S3), not one broad role — shows production instinct, not just "it works."
4. Mention the **S3 lifecycle → Glacier transition** for cost — shows you've thought about what long-term archival actually costs, not just that it's technically possible.
