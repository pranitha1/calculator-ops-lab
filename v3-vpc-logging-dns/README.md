# v3 — VPC Flow Logs, S3 log bucket, internal DNS practice, firewall change practice

Goal: practice the networking/logging/DNS/firewall parts of the JD, operating on
the existing default VPC (the way a support engineer works within an
already-built "landing zone" rather than building VPCs from scratch).

**Note:** Route 53 private hosted zones cost ~$0.50/month flat (never free-tier),
so this version stays $0 by simulating internal DNS via `/etc/hosts` on the
instance instead of a real hosted zone. The operational skill — resolving
friendly internal names instead of hardcoding IPs/endpoints — is the same one
the JD is testing for; only the underlying AWS service differs. If you later
want the real Route 53 version, it's a small add-on we can do anytime.

## What this provisions
- An S3 bucket (`calculator-ops-lab-flow-logs-<account-id>`) with a bucket policy
  scoped to allow only the AWS log-delivery service to write into it — encrypted,
  no public access, 30-day lifecycle expiration
- **VPC Flow Logs** on the default VPC, delivered to that bucket (captures ALL traffic — accepted and rejected)

## Step 1 — Apply

```bash
terraform init
terraform plan
terraform apply
```

## Step 2 — Verify Flow Logs are landing in S3
Flow logs take 5-15 min to start appearing. Once they do:
```bash
aws s3 ls s3://calculator-ops-lab-flow-logs-<account-id>/AWSLogs/ --recursive
```

## Step 3 — Internal DNS practice (free, via /etc/hosts + SSM)
```bash
aws ssm send-command --region us-east-1 --instance-ids i-0eed159de00307b92 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["echo \"127.0.0.1 app.calculator.internal\" >> /etc/hosts","echo \"172.31.21.167 db.calculator.internal\" >> /etc/hosts","ping -c 1 app.calculator.internal","ping -c 1 db.calculator.internal"]'
```
This gives the instance friendly internal names instead of hardcoded IPs/endpoints — the same underlying idea as a private hosted zone, just without the recurring cost.

## Step 4 — Firewall change request drill (do this one yourself, console)
This simulates the JD's "firewall change request coordination":
1. Pretend you received a ticket: "Allow port 8080 inbound from 10.0.0.0/8 on calculator-v1-sg for a new monitoring agent"
2. EC2 console → Security Groups → `calculator-v1-sg` → Edit inbound rules → add the rule
3. Verify it's there: `aws ec2 describe-security-groups --group-ids sg-0119e966ae1e426cb --region us-east-1`
4. Write one paragraph as if it were a change-ticket close-out note (what changed, why, who requested it, rollback plan)
5. Remove the rule again (this was just a drill) and verify it's gone

This documentation habit — even for a one-line firewall change — is exactly what
"strong communication, documentation, ownership" means in the JD.
