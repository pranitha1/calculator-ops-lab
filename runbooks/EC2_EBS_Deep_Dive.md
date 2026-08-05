# EC2 & EBS — Deep Dive for AWS Cloud Ops
### Mapped to the Cognizant AWS Cloud Operations JD
**Grounded in our real lab: `ops-lab-ec2-ssm-role`, the v4 ASG, `facets-standalone-practice`.**

---

## WHY THIS IS THE THIRD-MOST-IMPORTANT TOPIC

EC2, EBS, and AMIs are each named separately in the qualifications list, and EC2 shows up across more responsibility lines than almost anything except CloudWatch:
- Resp. #1: *"daily AWS cloud infrastructure health checks... EC2/RDS availability"*
- Resp. #5: *"EBS snapshot activities, EBS disk sizing requests, backup validation for EC2"*
- Resp. #7: *"EC2/container restarts... infrastructure troubleshooting"*
- Resp. #8: *"AMI and S3 object sharing across AWS accounts, EC2 instance restarts... infrastructure resizing guided by FME"*

It's also the topic where we've hit the most real, unplanned bugs — which is exactly the kind of material worth leading with in an interview, per last session's coaching.

---

# PART 1 — CORE CONCEPTS

## 1.1 Instance lifecycle states — and the distinction that actually matters operationally

`pending → running → stopping → stopped → shutting-down → terminated`

The one that trips people up: **stop vs. terminate are not degrees of the same action.**
- **Stop**: the instance shuts down, but the **root EBS volume persists**. You can start it again later — same instance ID, same data, though it may land on *different underlying hardware* (this is exactly why "stop/start" is the fix for a `StatusCheckFailed_System` hardware problem, while a plain reboot is not — see §1.3).
- **Terminate**: the instance is gone permanently. By default the root EBS volume is deleted with it (`DeleteOnTermination`), unless that flag was explicitly set to false at launch — a real, common data-loss trap worth knowing about before it happens to you.

We used this distinction for real: pausing the lab between sessions always meant scaling the ASG to 0 (which **terminates** the instances — they're stateless, rebuilt from the launch template every time) rather than stopping them, since ASG-managed instances aren't meant to be individually preserved.

## 1.2 Status checks — System vs. Instance (recap, full depth in CloudWatch_Deep_Dive_Addendum.md)

`StatusCheckFailed_System` = AWS hardware fault, fixed only by migrating hardware (stop/start, or EC2 Auto-Recovery). `StatusCheckFailed_Instance` = your OS's fault (kernel panic, disk full, bad network config inside the guest) — fixed by you, a reboot, or replacement. We got this backwards once in an earlier session and corrected it — worth having crisp, since it's one of the most commonly asked ops questions.

## 1.3 EC2 Auto-Recovery — built for real, and the architectural judgment that goes with it

We built this hands-on on a standalone instance (`facets-standalone-practice`): a CloudWatch alarm on `StatusCheckFailed_System >= 1`, statistic **Maximum** (binary metrics need Maximum, not Average — a real failure gets diluted below threshold otherwise), with the EC2 **Recover this instance** action attached (`arn:aws:automate:us-east-1:ec2:recover`) plus an SNS notification.

**The judgment call that matters more than the mechanics**: Auto-Recovery is designed for **standalone, non-ASG instances** — it preserves the exact same instance (ID, private IP, EBS data) by migrating it to healthy hardware. For **ASG-managed fleets** (our v4 setup), it's the *wrong* tool — the ASG's own health-check-based replacement already covers hardware failures *and* every other failure mode (OS crash, app crash, network issue), and layering Auto-Recovery on top risks two independent remediation systems fighting over the same instance simultaneously. We deliberately built this on a standalone throwaway instance for exactly this reason, not on the ASG fleet.

## 1.4 Instance metadata service and IAM roles

An instance role (`ops-lab-ec2-ssm-role`, attached via an instance profile) lets code running on the instance fetch temporary, auto-rotating credentials from the metadata service (`169.254.169.254`) — no access keys ever touch the instance's disk or code. Full depth in [IAM_Deep_Dive.md](IAM_Deep_Dive.md) §1.4/UC-1.

## 1.5 User data / bootstrap scripts — what actually runs, and a real gotcha we hit

User data (our `bootstrap.sh`) runs once, at first boot, as root, before anything else on the instance is generally usable. It's how our launch template installs Flask, writes `app.py`, configures the systemd service, and installs the CloudWatch Agent — all without manual per-instance setup.

**The real bug this surfaced**: our app's `init_db()` tries to connect to RDS immediately at import time, with no retry/backoff. When an EC2 instance boots faster than RDS finishes starting (a genuine race condition we hit during a real resume), the process crashes immediately — and **systemd's restart-rate-limiter gives up entirely** ("Start request repeated too quickly") rather than retrying indefinitely. This is a real, still-unfixed bug in our lab, and a genuinely good interview story about boot-order dependencies between infrastructure tiers.

## 1.6 EBS fundamentals

- **Volume types**: `gp3` (general purpose SSD, current default — better price/performance than `gp2`), `io1`/`io2` (provisioned IOPS, for latency-sensitive workloads), `st1`/`sc1` (throughput-optimized/cold HDD, for large sequential workloads like log processing, not boot volumes)
- **Root volume vs. additional volumes**: the root volume holds the OS and typically gets deleted on termination by default (§1.1); additional attached volumes can persist independently
- **Snapshots**: point-in-time, incremental (only changed blocks after the first snapshot are stored, keeping cost down) backups of a volume, stored in S3 behind the scenes but not directly accessible as S3 objects

## 1.7 EBS Elastic Volumes — live resize, no downtime, two-step process

This is a real capability we've discussed in depth but **not yet executed hands-on for an EC2 volume specifically** (we did do the equivalent for RDS storage in v2, for real). Worth completing as a lab — see Part 3.

The two steps, both live:
1. `aws ec2 modify-volume --volume-id vol-xxxx --size N` — expands the raw block device. Works on a running instance, no stop required.
2. **The OS still needs to be told about the new space** — this step is separate and easy to forget:
   - **Linux**: `growpart` (extend the partition) then `resize2fs` (ext4) or `xfs_growfs` (XFS) — both run live, no reboot
   - **Windows**: Disk Management → **Extend Volume**, or `Resize-Partition` in PowerShell — also live on a standard EC2 boot volume

## 1.8 AMIs — creation and cross-account sharing (real gap, not yet built)

An AMI is a snapshot of an instance's root volume plus launch configuration (instance type compatibility, block device mapping), used to launch identical new instances without re-running the bootstrap process each time — the "golden image" pattern referenced back in our earlier discussion of how EC2 fleets scale in real production (bake config into the AMI rather than installing at every boot).

**Cross-account sharing** (JD, explicit line): `aws ec2 modify-image-attribute --image-id ami-xxxx --launch-permission "Add=[{UserId=TARGET_ACCOUNT_ID}]"` — grants a specific account (or an AWS Organization) permission to launch instances from that AMI. This is a genuine, currently-untouched gap in our lab — see Part 3, Lab 4.

## 1.9 The free-tier / instance-type gotcha we hit twice

`t2.micro` is the "traditional" free-tier example everywhere in AWS documentation — but this account's actual free-tier-eligible list only includes `t3.micro`, `t4g.micro`, `t3.small`, and a couple of `-flex` types. We discovered this the hard way when the ASG launch template originally specified `t2.micro` and every launch failed with *"The specified instance type is not eligible for Free Tier."* Always verify with `aws ec2 describe-instance-types --filters "Name=free-tier-eligible,Values=true"` for the *actual* account rather than assuming from older documentation or tutorials.

## 1.10 Stop/start vs. reboot — when each actually fixes something

- **Reboot**: same underlying hardware, same instance. Fixes OS-level hangs, applies certain config changes requiring a restart. Does **not** help with a hardware-level problem.
- **Stop then start**: instance may land on **different physical hardware** entirely (its EBS volumes persist and reattach, but the host underneath can change). This is why stop/start — not reboot — is the manual fix for a `StatusCheckFailed_System` issue, and exactly what EC2 Auto-Recovery automates.

---

# PART 2 — LIVE PRODUCTION USE CASES

## UC-1: Manual provisioning as a support engineer, and why we did it that way

**Context**: our very first instance in this lab (`v1`) was launched manually through the console — deliberately, not via Terraform — because this JD is console/CLI operations, not infrastructure-as-code. Knowing the actual launch wizard (AMI selection, instance type, IAM instance profile, security group, user data) cold is more interview-relevant than knowing how to template it.

## UC-2: Fleet management via Auto Scaling + Launch Templates — self-healing, witnessed for real multiple times

Our v4 ASG replaced unhealthy instances automatically on at least three separate real occasions in this lab: once during initial buildout when an instance failed health checks, once during a resume when the DB-connection race condition (§1.5) crash-looped an instance, and once during the deliberate NACL incident drill when an instance landed in the wrong subnet. Each time, the ASG detected the failure via its ELB health check and launched a replacement with zero manual intervention — the practical meaning of "self-healing" beyond the buzzword.

## UC-3: EC2 instance restart troubleshooting (JD, explicit line: "EC2 instance restarts")

**Problem**: an application on an instance is unresponsive, but the instance itself passes status checks.

**Implementation**: connect via **Session Manager** (no SSH key needed — this is the JD-relevant access pattern), check the specific service (`systemctl status`, `journalctl -u <service>`), and restart at the *service* level first rather than the instance level where possible — an instance-level restart is a bigger hammer than usually necessary and takes longer. Instance-level restart (reboot, or stop/start for a hardware-suspected issue) is the escalation if the service itself won't recover.

## UC-4: EBS disk sizing request (JD, explicit line: "EBS disk sizing requests")

**Problem**: a ticket comes in requesting more disk space on a specific instance, or your own disk-space alarm (CloudWatch_Deep_Dive UC-3) triggers one internally.

**Implementation**: the two-step Elastic Volumes process from §1.7 — resize the volume, then extend the OS partition/filesystem. Entirely online, no downtime, matching the same "no stop required" principle we established for RDS storage resizing.

## UC-5: Golden AMI for consistent, fast fleet provisioning

**Problem**: baking software into every instance at boot time (our `bootstrap.sh` approach) means a 1-2 minute delay per instance launch, and "did the install step succeed on every instance" becomes its own monitoring problem at scale.

**Implementation**: build an AMI with the application/agent already installed (via Packer or EC2 Image Builder in a real pipeline), so new instances boot in seconds with guaranteed-identical software, no install step at runtime. This is the "why bootstrap.sh isn't how it'd really be done at scale" answer from our earlier scaling discussion, made concrete.

## UC-6: Cross-account AMI sharing (JD, explicit line, real gap)

**Problem**: a DR region/account, or a separate client environment, needs to launch instances from an AMI built in the primary account.

**Implementation**: §1.8's `modify-image-attribute` launch-permission grant. Worth remembering the S3 parallel too — if the AMI's underlying snapshot lives in a specific account, the receiving account needs both the AMI launch permission *and*, if directly touching the snapshot, appropriate KMS key permissions if it's encrypted.

---

# PART 3 — HANDS-ON LABS (using our real account)

## LAB 1 — Already done: manual launch (reference, not to repeat)

Our v1 instance was launched exactly this way; see [v1-single-ec2/README.md](../v1-single-ec2/README.md) for the exact console steps we used (AMI selection, `t3.micro`, IAM instance profile, security group, user data).

## LAB 2 — Already done: Session Manager access (reference)

Used throughout this entire lab for troubleshooting, log checking, and diagnosis — no SSH key ever created or used.

## LAB 3 — NEW: EBS volume resize on a real EC2 instance (not yet executed — do this one)

1. Resume the ASG (`min_size`/`desired_capacity` back to 1-2 in `v4-asg-alb/main.tf`, `terraform apply`)
2. Get the root volume ID of one running instance:
```bash
aws ec2 describe-instances --instance-ids <id> --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text
```
3. Resize it live:
```bash
aws ec2 modify-volume --volume-id <vol-id> --size 12
```
4. Via Session Manager on that instance:
```bash
lsblk
sudo growpart /dev/xvda 1
sudo resize2fs /dev/xvda1
df -h
```
5. Confirm the new size shows in `df -h` — this is the concrete proof that step 3 alone (the AWS-side resize) isn't sufficient; the OS-side extension in step 4 is what actually makes the space usable.

## LAB 4 — NEW: Create an AMI (real gap, closes it)

1. From a running instance: **EC2 console → select instance → Actions → Image and templates → Create image**
2. Name it, leave default settings, **Create image**
3. **EC2 → AMIs**, wait for status `available` (a few minutes)
4. Select the AMI → **Actions → Edit AMI permissions** — this is where you'd add a specific account ID for cross-account sharing (§1.8/UC-6). You don't need a second account to see the mechanism; adding then removing a placeholder account ID demonstrates the workflow.
5. Optionally: launch a new instance from this AMI and confirm it boots with your application already present — proof the golden-image pattern actually works, versus re-running `bootstrap.sh`.

## LAB 5 — Already done: EC2 Auto-Recovery (reference)

Built on `facets-standalone-practice`, verified via `describe-alarms` showing both `arn:aws:automate:us-east-1:ec2:recover` and the SNS action attached, statistic `Maximum`. See earlier session notes / [CloudWatch_Deep_Dive_Addendum.md](CloudWatch_Deep_Dive_Addendum.md).

## LAB 6 — Cleanup

1. Deregister the AMI from Lab 4 if you don't want it lingering (**EC2 → AMIs → Deregister**) — note this does *not* automatically delete the underlying snapshot, which must be deleted separately from **EC2 → Snapshots** or it keeps costing storage
2. Revert the volume size change from Lab 3 if desired (note: EBS volumes, like RDS storage, **can only grow, never shrink** — this isn't reversible, just something to be deliberate about before resizing a real production volume)
3. Pause the lab as usual (ASG to 0, RDS stopped) if done for the session

---

# PART 4 — INTERVIEW QUESTIONS

## Fundamentals

**Q: What's the difference between stopping and terminating an instance?**
Stopping shuts the instance down but preserves the root EBS volume — you can start it again later, same instance ID and data, though it may land on different underlying hardware. Terminating deletes the instance permanently, and by default deletes the root volume with it unless `DeleteOnTermination` was explicitly set to false at launch — which is a real, common way to lose data unexpectedly if nobody checked that flag.

**Q: When would you reboot an instance versus stop and start it?**
Reboot keeps the same underlying hardware and just restarts the OS — fine for OS-level hangs or config changes needing a restart. Stop/start can move the instance to different physical hardware entirely, which is why it's the actual fix for a `StatusCheckFailed_System` hardware-level problem — a plain reboot wouldn't help since you'd likely land back on the same faulty host.

**Q: Walk me through resizing an EBS volume without downtime.**
It's a two-step process, both live. First, `modify-volume` to increase the size at the block-device level — that alone doesn't change what the OS sees. Second, you extend the actual partition and filesystem on top of it — `growpart` then `resize2fs` on Linux, or Extend Volume in Disk Management on Windows. Skipping the second step is a common mistake — the volume shows the new size in the console, but `df -h` inside the instance still shows the old size until the filesystem is actually extended.

**Q: What's an AMI, and why would you use one instead of installing software at boot every time?**
An AMI is a snapshot of an instance's root volume plus its launch configuration, used to launch new instances that already have everything pre-installed. Installing at boot time via user data works but adds a delay to every launch and makes "did the install actually succeed" its own thing you have to monitor per instance. A golden AMI with the software already baked in launches in seconds and is guaranteed identical every time.

## Scenario questions

**Q: A ticket asks you to resize an instance's disk from 8GB to 20GB. Walk me through it, including anything that could go wrong.**
I'd confirm the request through change management first — even a live-resize is still a production change. Then `modify-volume` for the size increase, which is online and doesn't require stopping the instance. The step people forget is extending the OS partition and filesystem afterward — `growpart` and `resize2fs` on Linux — without that, the instance still reports the old, smaller size even though AWS shows the volume as resized. I'd verify with `df -h` before closing the ticket. Worth remembering EBS volumes can only grow, never shrink, so I'd confirm the requested size is actually correct before applying it, since there's no undo.

**Q: You need to share a custom AMI with a partner's AWS account for a joint project. How do you do it, and what would you check before agreeing to it?**
Technically it's `modify-image-attribute` adding a launch permission for their account ID. Before doing it, I'd want to know what's actually baked into that AMI — if it contains any credentials, internal hostnames, or sensitive configuration that shouldn't leave the account, sharing the AMI directly would leak that to them. I'd also check whether the underlying EBS snapshot is encrypted with a customer-managed KMS key, since the receiving account would additionally need permission on that key, not just the AMI itself, or the share silently won't work for them.

**Q: An instance keeps failing to launch in your Auto Scaling Group with an error about Free Tier eligibility. What's actually happening?**
This is something I've hit directly — `t2.micro` is the instance type most documentation and tutorials default to, but not every account's actual free-tier-eligible list includes it; some accounts only have `t3.micro` and similar current-generation types. The fix is checking the account's real eligible list with `describe-instance-types --filters Name=free-tier-eligible,Values=true` rather than assuming from older documentation, and updating the launch template to match what's actually eligible for that specific account.

**Q: How do you decide between EC2 Auto-Recovery and just letting an Auto Scaling Group replace a failed instance?**
It depends entirely on whether the instance is standalone or fleet-managed. Auto-Recovery is built for standalone instances where you need to preserve that exact instance's identity and data — it migrates to new hardware but keeps the same instance ID, private IP, and attached volumes. For an ASG-managed instance, the ASG's own health-check-based replacement already handles hardware failures and everything else — OS crashes, app crashes, network issues — more broadly than Auto-Recovery's narrower hardware-only scope. Layering both on the same instance risks two separate remediation systems acting on it at the same time, so I'd pick one based on the architecture, not use both by default.

---

# PART 5 — QUICK REFERENCE

## Stop / Terminate / Reboot cheat sheet

| Action | Root EBS volume | Underlying hardware | Instance ID |
|---|---|---|---|
| Reboot | Unchanged | Same | Same |
| Stop → Start | Preserved | **May change** | Same |
| Terminate | Deleted by default (unless `DeleteOnTermination=false`) | N/A | Gone |

## EBS volume type cheat sheet

| Type | Use case |
|---|---|
| gp3 | Default general-purpose SSD, best price/performance |
| io1 / io2 | Latency-sensitive, high-IOPS workloads (databases) |
| st1 / sc1 | Large sequential throughput (log processing) — never for boot volumes |

## Common mistakes to avoid (and to mention when asked)

1. Assuming `t2.micro` is free-tier eligible on every account — check the account's actual eligible list
2. Resizing an EBS volume and stopping there — forgetting the OS-side `growpart`/`resize2fs` step
3. Terminating an instance without checking `DeleteOnTermination` first, losing data unexpectedly
4. Using EC2 Auto-Recovery on an ASG-managed instance, creating a conflict with the ASG's own health-check replacement
5. Rebooting an instance to fix a `StatusCheckFailed_System` issue — a reboot doesn't change the underlying hardware, only stop/start does
6. Sharing an AMI cross-account without checking what's baked into it, or forgetting KMS key permissions if the snapshot is encrypted
7. Deregistering an AMI and assuming the underlying snapshot is automatically deleted too — it isn't, and keeps costing storage

## Study sequence

| Session | Labs | Focus |
|---|---|---|
| 1 | 3 | EBS resize on a real instance — the one gap left from earlier discussion |
| 2 | 4 | AMI creation + cross-account permission mechanics |
| 3 | 6 | Cleanup |
| 4 | — | Answer every Part 4 question out loud |
