# CloudWatch Deep Dive — Session Addendum

Companion to the main CloudWatch Deep Dive reference doc. Covers gaps found
when auditing that document against the actual JD text, plus two places
where our own hands-on session in this lab found something more current
than the reference material itself.

---

## A.1 CloudWatch cross-account observability (the CloudWatch-side counterpart to IAM Identity Center)

Directly parallel to the landing-zone gap fixed in [IAM_Deep_Dive.md](IAM_Deep_Dive.md) — same "LZ2" signal, different service.

**What it is**: a **monitoring account** (typically the landing zone's central Security/Audit or dedicated Observability account) can view metrics, dashboards, and logs from **multiple source accounts** across the Organization, without needing to log into each one separately. Set up via **CloudWatch → Settings → Cross-account observability**, which uses **AWS Observability Access Manager (OAM)** under the hood: each source account creates a "sink" accepting shared data, and the monitoring account creates a "link" to each sink it wants visibility into.

**Why this matters for this JD specifically**: in a real multi-account landing zone, an ops engineer troubleshooting "is anything unhealthy across our accounts" would use exactly this — one CloudWatch console showing alarms/dashboards aggregated from every account, rather than switching consoles per account. This is the practical, daily-use version of the "AWS account access within the LZ2 landing zone" line, applied to monitoring specifically.

**Honest limitation**: like IAM cross-account AssumeRole, this genuinely needs a second AWS account to build for real. Understanding the OAM sink/link model conceptually is what's realistic to have ready without one.

**Interview answer**: *"In a multi-account landing zone, I wouldn't expect to monitor by logging into each account separately — CloudWatch cross-account observability, via AWS Observability Access Manager, lets a central monitoring account see metrics, dashboards, and logs from every linked source account in one place."*

## A.2 Mute Rules — the current console feature, not manual disable/enable

We found this hands-on, on the live console, while working through a maintenance-window scenario. The reference document's guidance (Actions → Disable actions) still works and is valid to know, but it's not the *best* current answer.

**CloudWatch → Alarms → select alarm(s) → Actions → Mute rules — new**, with two paths:
- **Quick mute**: `Mute for 15min` / `1h` / `3h` / `Mute until...` — all **time-bound by design**, auto-expiring without any manual re-enable step
- **Manage mute rules**: create a **named, reusable** mute rule (e.g., a standing "Saturday deployment window" rule) rather than reconfiguring quick-mute each time

**Why this matters more than it first appears**: the reference document's own UC-7 warns that the classic failure mode is *"suppressing alarms on Saturday and discovering on Wednesday that production has been unmonitored for four days."* Mute Rules structurally eliminates that exact failure — the mute expires on its own, whether or not a human remembers the runbook's re-enable step. Manual disable/enable is still worth knowing (it's non-expiring, useful when you deliberately want indefinite suppression), but "Mute until [maintenance window end time]" is the sharper interview answer for the deployment-noise scenario specifically.

## A.3 Monitoring SSM agent status — the JD's literal first line, and the answer isn't a custom metric

The JD's very first responsibility line names "SSM agent status" explicitly, but there's no built-in CloudWatch metric for "is this fleet's SSM agent still checking in." We worked through the naive answer and the better one in this lab:

- **Naive answer** (over-engineered, don't lead with this): write a scheduled Lambda that runs `aws ssm describe-instance-information`, compares against your actual instance count, and publishes the gap as a custom CloudWatch metric.
- **Better answer**: **AWS Config's managed rule `ec2-instance-managed-by-systems-manager`** — a native, continuous compliance check requiring zero custom code, whose non-compliant findings can be routed to EventBridge → SNS using the exact same alerting pattern as everything else in this lab.

**Interview answer**: *"There's no native CloudWatch metric for SSM agent health directly. Rather than building custom instrumentation, I'd reach for AWS Config's managed rule for SSM-managed compliance first — it's the native tool for exactly this, and building a custom Lambda-based metric for something a managed rule already solves would be a design smell, not a strength."*

## A.4 Long-term metric retention / export — already covered in depth elsewhere

The main document's §1.2 correctly states the 15-month retention limit and that export is required beyond it, but doesn't build out the how. That build-out already exists in this lab: see **[cloudwatch-long-term-metrics-runbook.md](cloudwatch-long-term-metrics-runbook.md)** — covers Metric Streams → Kinesis Firehose → S3 (with the "doesn't backfill" limitation explicit), least-privilege IAM per hop, S3→Glacier lifecycle for cost, and the `GetMetricData` batch-export path for preserving existing history before it ages out. No need to duplicate it here.
