# v1 — Calculator on a single EC2 instance

Goal: practice EC2 launch, IAM instance roles, SSM agent management, security groups,
and basic health checks — manually, through the console.

## Step 1 — Create an IAM role for the instance (console)

1. IAM → Roles → **Create role**
2. Trusted entity: **AWS service** → Use case: **EC2**
3. Attach policy: **AmazonSSMManagedInstanceCore**
4. Name it `ops-lab-ec2-ssm-role` → Create

This lets Systems Manager (SSM) manage the instance without needing SSH keys —
you'll check "SSM agent status" through this, straight from the JD.

## Step 2 — Launch the EC2 instance (console)

1. EC2 → **Launch instance**
2. Name: `calculator-v1`
3. AMI: **Amazon Linux 2023** (SSM agent is pre-installed)
4. Instance type: `t2.micro` (free tier)
5. Key pair: **Proceed without a key pair** (we're using SSM Session Manager instead)
6. Network settings → Edit:
   - Create a new security group `calculator-v1-sg`
   - Add inbound rule: **Custom TCP, port 5000, source = My IP** (not 0.0.0.0/0 — don't expose this publicly)
7. Advanced details → **IAM instance profile**: select `ops-lab-ec2-ssm-role`
8. Advanced details → **User data**: paste the contents of [`user-data.sh`](user-data.sh)
9. Launch

Wait ~2 minutes for boot + bootstrap to finish, then tell me and I'll verify everything via CLI.

## What I'll verify once it's up
- Instance state and status checks (`aws ec2 describe-instances` / `describe-instance-status`)
- SSM agent ping status (`aws ssm describe-instance-information`)
- App health via SSM run-command (`curl localhost:5000/health` on the instance, plus disk usage with `df -h`)
- `/calculate` endpoint working end-to-end

## Manual practice once it's verified
- Use **Session Manager** (EC2 console → instance → Connect → Session Manager) to get a shell with no SSH key
- Run `df -h`, `systemctl status calculator`, `journalctl -u calculator -f` — these are exactly the kind of daily health-check commands the JD describes
