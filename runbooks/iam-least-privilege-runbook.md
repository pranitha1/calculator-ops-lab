# Runbook: IAM Least-Privilege Design for an AWS Ops Support Role

Maps to JD qualifications ("IAM/access") and responsibility #6 ("manage...
AWS account access within the LZ2 landing zone environment"). Covers
designing, building, and verifying a properly scoped role — not just naming
the concept of least privilege.

## Why this matters operationally

A single over-privileged credential (like this lab's `ops-lab-cli`, which has
had `AdministratorAccess` the whole time) is a real production anti-pattern:
one compromised credential or one mistaken command has account-wide blast
radius. In a real environment, the identity a human ops engineer logs in
with should be scoped to exactly the job — broad enough to do the work
without daily friction, narrow enough that a mistake or compromise can't
touch IAM itself, networking, or billing.

## Step 1 — Separate "who builds it" from "who operates it"

Don't retrofit a least-privilege policy onto a credential that's already
doing broad platform/build work (Terraform, CI/CD) — that identity
legitimately needs broad permissions. Instead, create a **separate** role/user
for day-to-day operations. Conflating the two is itself the anti-pattern.

## Step 2 — Scope the operations role to the actual job

Based strictly on this JD's named responsibilities:

**Should be able to:**
- Read/describe broadly (visibility is the job — health checks, dashboards, troubleshooting)
- EC2: start/stop/reboot instances, create AMIs, modify EBS volumes
- RDS: create/restore snapshots, modify allocated storage
- CloudWatch: create/modify alarms, dashboards, metric filters, alarm actions/mute rules
- SSM: Run Command, Parameter Store read/write, Session Manager
- S3: read + write to *specific* operational/log buckets only — never `s3:*` on `*`
- Route 53: manage records within specific hosted zones
- ACM: import/request certificates

**Should NOT be able to:**
- Create, delete, or modify IAM users, roles, or policies — including its own (no privilege escalation path)
- Create/delete VPCs, subnets, or core networking
- Touch billing or account-level settings

## Step 3 — Example scoped policy (template — replace bucket/zone ARNs with real ones)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyVisibility",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*", "rds:Describe*", "cloudwatch:Describe*",
        "cloudwatch:Get*", "cloudwatch:List*", "logs:Describe*",
        "logs:Get*", "logs:FilterLogEvents", "logs:StartQuery",
        "logs:GetQueryResults", "ssm:Describe*", "ssm:Get*",
        "ssm:List*", "s3:GetBucket*", "s3:ListBucket",
        "route53:Get*", "route53:List*", "acm:Describe*", "acm:List*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2Operations",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances",
        "ec2:CreateImage", "ec2:ModifyVolume", "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RDSOperations",
      "Effect": "Allow",
      "Action": [
        "rds:CreateDBSnapshot", "rds:RestoreDBInstanceFromDBSnapshot",
        "rds:ModifyDBInstance", "rds:StartDBInstance", "rds:StopDBInstance"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchOperations",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
        "cloudwatch:EnableAlarmActions", "cloudwatch:DisableAlarmActions",
        "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
        "logs:PutMetricFilter", "logs:DeleteMetricFilter"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMOperations",
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand", "ssm:StartSession", "ssm:TerminateSession",
        "ssm:PutParameter"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ScopedS3Access",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::REPLACE-WITH-YOUR-LOG-BUCKET/*"
    },
    {
      "Sid": "ExplicitDenyIAMAndNetworking",
      "Effect": "Deny",
      "Action": [
        "iam:CreateUser", "iam:CreateRole", "iam:DeleteRole",
        "iam:AttachRolePolicy", "iam:PutRolePolicy", "iam:CreateAccessKey",
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:CreateSubnet"
      ],
      "Resource": "*"
    }
  ]
}
```

The explicit `Deny` block at the end is deliberate belt-and-suspenders — even
if a future edit accidentally adds a broad `Allow` elsewhere, an explicit
`Deny` always wins in IAM's evaluation logic and blocks privilege escalation.

## Step 4 — Verify it actually works, both directions

Don't trust a policy because it "looks right" — same discipline as the
CloudWatch metric filter lesson. Use `simulate-principal-policy` to test
*before* deploying:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::ACCOUNT_ID:role/ops-support-role \
  --action-names ec2:StopInstances iam:CreateRole \
  --resource-arns "*"
```
Expect `allowed` for the first, `implicitDeny` or `explicitDeny` for the second.

## Step 5 — Audit for drift and unused permissions

- **IAM Access Analyzer** (IAM console → Access Analyzer): flags resources shared with entities outside your account/org, and validates policies for overly permissive statements before you attach them
- **Access Advisor tab** (on any user/role's IAM console page): shows *last-used* timestamp per service — the practical way to find permissions granted but never actually exercised, and safely remove them
- `aws iam get-account-authorization-details`: full dump of every user, role, group, and policy in the account — useful for a point-in-time audit or offline review

## Related concepts worth knowing, not built here

- **Permission boundaries**: a second policy that caps the *maximum* permissions a role can ever have, even if its attached policy grants more — used so a team can create their own IAM roles without being able to escalate beyond an approved ceiling
- **Cross-account access (AssumeRole)**: the mechanism behind AMI/S3 sharing across accounts — a role in Account B trusts Account A's principal, and Account A's user calls `sts:AssumeRole` to get temporary credentials scoped to Account B. Genuinely requires a second AWS account to practice meaningfully; not built in this lab.
