# IAM & Access — Deep Dive for AWS Cloud Ops
### Mapped to the Cognizant AWS Cloud Operations JD
**All labs use our real lab account (`ops-lab-cli`, `ops-lab-ec2-ssm-role`) — no throwaway examples.**

---

## WHY IAM IS THE SECOND-MOST-IMPORTANT TOPIC FOR THIS ROLE

The JD names it twice, in two different ways:
1. Qualifications: *"Hands-on AWS operations experience across EC2, EBS, RDS, S3, VPC, Route 53 Private Hosted Zones, CloudWatch, SSM, AMIs, **IAM/access**."*
2. Responsibility #6: *"Manage VPC Flow Logs, EC2 logs, log bucket access, S3 bucket access policies, and **AWS account access within the LZ2 landing zone environment**."*

More than that: every single thing we've built in this lab — EC2, RDS, S3, CloudWatch, SSM, VPC — required an IAM permission underneath it. IAM isn't a separate silo of knowledge; it's the substrate everything else sits on. If you understand it shallowly, every other topic has a hidden weak point.

---

# PART 1 — CORE CONCEPTS (NOTES)

## 1.1 The five entities

| Entity | What it is | Real example from our lab |
|---|---|---|
| **User** | A persistent identity, usually for a human or a long-lived script | `ops-lab-cli` — our CLI credential |
| **Group** | A named bundle of users sharing permissions | Not used in our lab — a real gap worth naming, see §1.8 |
| **Role** | A *temporary* identity, assumed rather than logged into | `ops-lab-ec2-ssm-role` — assumed by EC2 instances |
| **Policy** | The JSON document that actually defines permissions | `AdministratorAccess`, `CloudWatchAgentServerPolicy`, our custom `calculator-ssm-parameter-read` |
| **Identity provider** | Federation — SSO/SAML/OIDC, lets external identities assume roles | Not used in our lab; real enterprises use this instead of raw IAM users for humans |

## 1.2 Policy types — this is where most confusion actually lives

- **Identity-based policy**: attached to a user, group, or role. Answers "what can *this identity* do." Every policy we've built in this lab so far is this type.
- **Resource-based policy**: attached to the resource itself, not an identity. Answers "who can act *on this resource*." **We've already built one without naming it**: the flow-logs S3 bucket policy (v3) granting `delivery.logs.amazonaws.com` write access — that's a resource-based policy. This is the *only* policy type that can grant access to a principal in a completely different AWS account directly, which is exactly the mechanism behind cross-account AMI/S3 sharing (§2.3).
- **Permission boundary**: a policy that sets the *maximum* an identity-based policy can ever grant, regardless of what that policy says. Used so a team can create their own roles without being able to escalate past an approved ceiling.
- **Service Control Policy (SCP)**: similar idea to a permission boundary, but enforced at the AWS Organizations account/OU level, not per-identity. Different mechanism, same spirit — a ceiling nothing inside can exceed.
- **Session policy**: passed at the moment a role is assumed, further restricting that specific session only, on top of whatever the role's own policy already allows.

## 1.3 Policy evaluation logic — the single most-tested IAM concept

The order, precisely:
1. **Default is implicit deny.** Nothing is allowed unless something explicitly allows it.
2. Check every applicable policy type — identity-based, resource-based, permission boundary, SCP (if in an Organization). **All of them must allow** the action for it to succeed.
3. **An explicit `Deny` anywhere always wins**, no matter how many `Allow` statements exist elsewhere, no matter which policy type it's in.

This is why our IAM runbook's example policy ends with an explicit `Deny` block on IAM self-modification and networking actions — it's not decorative, it's a structural guarantee. Even if someone later attaches a broad `Allow` by mistake, that `Deny` still wins.

## 1.4 Roles vs. users — when to use which

**Default answer: use a role, not a user, for anything that can use one.** Roles issue short-lived, auto-rotating credentials (via STS); users typically mean long-lived access keys sitting somewhere waiting to be leaked.

- **EC2 instances**: instance role + instance profile (`ops-lab-ec2-ssm-role`) — the instance fetches temporary credentials from its metadata service, nothing is ever stored on disk
- **Lambda functions**: an execution role, same underlying mechanism
- **Cross-account access**: a role in the target account, assumed via `sts:AssumeRole`
- **Federated/SSO humans**: a role mapped to their SSO permission set, not a raw IAM user at all
- **Service-linked roles**: AWS itself creates and uses these to act on your behalf — this is exactly the `AWSServiceRoleForAmazonSSM` role we had to create manually when it was missing, during the CloudWatch Agent SSM Parameter Store exercise

**Where our lab is honestly an anti-pattern**: `ops-lab-cli` is a *user* with long-lived access keys and `AdministratorAccess` — reasonable for solo lab convenience, wrong for how a real team would do it (a human would typically get temporary credentials via SSO/Identity Center, not a static access key).

## 1.5 Access keys and their risk

Long-lived access keys are one of the most common real incident causes in cloud security — accidentally committed to a public GitHub repo, leaked in a build log, left in a config file. If something can use a role instead, it should. If a user genuinely needs keys, rotate them regularly and never let them touch source control.

Separately: **the root account should never be used day-to-day**, and MFA on it is non-negotiable — root has permissions nothing else can override, including the ability to close the account.

## 1.6 Cross-account access (the AssumeRole mechanic)

Two policies work together, in two different accounts:
- A **trust policy** (resource-based, attached to the role in the *target* account) — says "I trust this specific principal from this other account to assume me"
- A **permission policy** (identity-based, on that same role) — says "once assumed, here's what you can actually do"

The calling side runs `sts:AssumeRole`, gets back temporary credentials scoped to that role, and uses those. For third-party (not-your-own) cross-account access, an **External ID** is added to the trust condition specifically to prevent the "confused deputy" problem — where a third party could otherwise be tricked into assuming a role on someone else's behalf.

**Honest limitation**: this genuinely needs a second AWS account to practice for real. Conceptual understanding is what's practical to build here.

## 1.7 Auditing tools — four different tools answering four different questions

| Tool | Answers | Not the same as |
|---|---|---|
| **IAM Access Analyzer** | "Is anything in my account shared with an external entity I didn't intend?" Also validates a policy *before* you attach it. | Not a log of past activity — it's a structural/config analysis |
| **Access Advisor** (tab on any user/role) | "Which services has this identity actually used, and when?" — great for finding *unused* granted permissions | Only shows service-level usage, not full API call detail |
| **CloudTrail** | The actual, complete log of every API call — who, what, when, from where | This is the real audit trail; Access Advisor is a summarized view of the same underlying data |
| **IAM Credential Report** | Account-wide CSV snapshot: every user, access key age, MFA status, password age | A point-in-time report, not a live query tool |

## 1.8 Least privilege in practice — the honest workflow, not the idealized one

Nobody designs a perfect least-privilege policy from a blank page on day one. The real workflow: start reasonably scoped (or with an AWS managed policy as a starting point), let the role/user actually operate for a period, then use **Access Advisor**'s last-used data to find granted-but-never-exercised permissions and remove them. Least privilege is an iterative *tightening* process, not a one-shot design exercise — say this in an interview, it reads as experienced rather than textbook.

**Group-based management** (which our lab never actually uses) is the real scaling mechanism for humans: attach permissions to a group matching a job function, add/remove users from the group as they join/change roles/leave, rather than hand-crafting an individual policy per person.

## 1.9 Cost/scale note

IAM itself has no direct cost — users, roles, and policies are free. The "cost" of bad IAM is entirely about **blast radius**: one over-permissioned credential, if compromised or misused, can reach far more than it should have been able to.

## 1.10 AWS Landing Zones — what "LZ2" in the JD actually means

Everything in §1.1–1.9 covers IAM *within a single account*. A **Landing Zone** is a different, larger thing: a pre-architected, multi-account AWS environment, typically built with **AWS Control Tower** (AWS-managed) or a **Landing Zone Accelerator** (more customizable, often used by large enterprises/SIs like Cognizant for client engagements). A landing zone standardizes:

- A **multi-account structure** — dedicated accounts for things like Log Archive (centralized CloudTrail/Config logs from every account), Security/Audit (read-only visibility across the whole org), and individual **workload accounts** per team/environment/business unit
- **Centralized guardrails** via Service Control Policies (§1.2) applied at the Organizational Unit level, so no account under that OU can ever exceed the ceiling — e.g., "no account in the Production OU can disable CloudTrail," enforced structurally, not by policy
- **Centralized human access** via IAM Identity Center (§1.12), so people log in *once* and get federated access to whichever accounts/roles they're permitioned for, rather than juggling separate credentials per account
- **Centralized logging and networking** — shared VPC patterns, centralized DNS, etc.

**Why "LZ2" specifically**: the naming strongly implies this client runs *multiple* landing zones — commonly seen for separating production from non-production, or splitting by business unit/regulatory boundary (very plausible for a healthcare payer, given HIPAA scope separation). You're not expected to have built one — a landing zone is set up once by a cloud foundations/platform team — but you're very likely to be the person **operating inside** one, which is exactly what responsibility #6's phrasing describes.

## 1.11 AWS Account creation (JD, responsibility #8: "Support AWS account creation")

This is a distinct skill from managing access within an account. In a landing zone, new accounts are provisioned through **AWS Organizations**, either manually (`Create account` in the Organizations console, specifying account name, root email, and which OU it lands in) or automatically via Control Tower's **Account Factory**, which additionally applies the org's baseline guardrails/networking/logging to the new account the moment it's created — no manual "hardening" step needed. "Supporting" account creation in an ops role typically means: submitting or validating the request, confirming the account landed in the correct OU (so it inherits the right SCPs), and confirming baseline setup (logging, guardrails) actually applied — not designing the landing zone's architecture itself.

## 1.12 IAM Identity Center (AWS SSO) — the actual mechanism behind centralized landing zone access

Referenced briefly in §1.4 as "the modern pattern" — here's the actual mechanism, since a landing zone's whole point is centralizing access through this rather than per-account IAM users:

- **Identity source**: where user identities actually live — AWS's own built-in directory, or federated from an external one (Active Directory, Okta, Azure AD) via SAML
- **Permission sets**: reusable, named bundles of policies (e.g., "ReadOnlyOps," "NetworkAdmin") — analogous to IAM policies, but designed to be assigned across *multiple* accounts at once, not just one
- **Account assignment**: a user or group gets a specific permission set assigned to a specific account — e.g., "Jane gets the ReadOnlyOps permission set in the Production workload account, and NetworkAdmin in the Networking account"
- **What actually happens under the hood**: Identity Center provisions a real IAM role in each assigned account for each permission set, and federated sign-in temporarily assumes that role — so it's built entirely on the AssumeRole mechanic from §1.6, just centrally managed instead of manually configured per account

This is why a real landing zone rarely has individual human IAM users at all — a human's actual access is a permission-set assignment in Identity Center, not a standalone IAM identity in each account.

## 1.13 Policy Condition blocks

A `Condition` element narrows *when* a policy statement applies, on top of the action/resource it already covers. Common real-world uses:

```json
{
  "Effect": "Allow",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::example-bucket/*",
  "Condition": {
    "IpAddress": { "aws:SourceIp": "203.0.113.0/24" },
    "Bool": { "aws:MultiFactorAuthPresent": "true" }
  }
}
```
This grants access only from a specific IP range *and* only if the caller authenticated with MFA — both must be true. Other common conditions: `aws:SourceVpc` (restrict to callers inside a specific VPC), date-based conditions for time-bound access, and `aws:PrincipalOrgID` (restrict to callers within your own AWS Organization — a common landing-zone-wide guardrail).

## 1.14 Account-wide password policy

A per-account setting (IAM console → Account settings, or Password policy) enforcing minimum length, complexity, expiration/rotation, and reuse prevention for any IAM users with console passwords. In a landing zone using Identity Center, this matters less for individual accounts (since humans authenticate centrally, not via per-account passwords) but is still worth knowing as a baseline account hygiene setting.

---

# PART 2 — LIVE PRODUCTION USE CASES

## UC-1: The instance role pattern (JD: "AWS account access")

**Problem**: an EC2 instance needs to call AWS APIs (publish to CloudWatch, read SSM parameters) without embedding access keys anywhere in code or the AMI — hardcoded keys on an instance are a severe, common real vulnerability.

**Implementation**: attach an IAM role via an instance profile at launch. The instance's software calls the metadata service (`169.254.169.254`) to fetch short-lived, auto-rotating credentials — nothing is ever stored on disk. This is exactly `ops-lab-ec2-ssm-role`, built in this lab from day one.

## UC-2: The "who can do this" investigation (JD: "access-related issues")

**Problem**: a user or service reports `AccessDenied` doing something that should plausibly be allowed.

**Implementation**: use `simulate-principal-policy` to test the exact action/resource combination *without* trial-and-error in production. Critically, also check for an **explicit Deny** on a completely different attached policy — these are easy to miss on a quick read-through of "the" policy, since the deny might live somewhere else entirely (a permission boundary, an SCP, a separate inline policy).

## UC-3: Cross-account AMI/S3 sharing (JD, responsibility #8, explicit line item)

**Problem**: a DR region/account needs a copy of an AMI, or specific S3 objects, from the primary account.

**Implementation, AMI**: `aws ec2 modify-image-attribute --launch-permission "Add=[{UserId=TARGET_ACCOUNT_ID}]"` — grants a specific account (or an AWS Organization) permission to launch instances from that AMI.

**Implementation, S3**: a **bucket policy** (resource-based — this is why §1.2's distinction matters) explicitly naming the external account's principal with the exact actions/objects allowed. Modern best practice is bucket policies with **S3 Block Public Access enabled account-wide**, not ACLs — ACLs are the legacy mechanism AWS itself now recommends against for virtually all use cases.

## UC-4: Onboarding / account access requests (JD: "AWS account creation," "AWS account access within LZ2")

**Problem**: a new engineer joins and needs scoped access, not a hand-built one-off policy.

**Implementation**: add them to an existing **group** matching their role (§1.8), not a bespoke policy per person — this is what actually scales past a handful of people. In a mature enterprise, this is more likely to be **AWS IAM Identity Center (SSO)** mapping the person to a permission set rather than creating a raw IAM user at all — worth naming this as the more current pattern even without hands-on access to it.

## UC-5: Preventing privilege escalation (a real, well-documented attack surface)

**Problem**: a role that can modify IAM policies — even ones scoped to "just what it needs" — can potentially grant *itself* more access than intended, if that includes actions like `iam:PutRolePolicy` or `iam:PassRole` combined with the right other permissions.

**Implementation**: explicit `Deny` on IAM self-modification actions (§1.3's evaluation-order guarantee is exactly what makes this reliable), combined with permission boundaries capping what any role created within a given scope can ever reach. There's a well-known, publicly documented list of ~20+ specific IAM privilege-escalation patterns (various `iam:PassRole` + other-service combinations) — worth knowing this *category* of risk exists even without memorizing the full list.

## UC-6: Access review / operational reporting (JD: "operational reporting")

**Problem**: a compliance or security team asks for a quarterly access review — who can do what, and is any of it stale.

**Implementation**: pull the **IAM Credential Report** for account-wide key age/MFA/password status, cross-referenced with **Access Advisor** data per role to flag permissions granted but never actually used in the review period.

## UC-7: A new workload account is requested (JD, responsibility #8: "Support AWS account creation")

**Problem**: a team needs a new AWS account for a project — say, a new non-production environment.

**Implementation**: the request goes through Organizations/Control Tower's Account Factory, specifying which **OU** the account should land in (this single choice determines which SCPs/guardrails automatically apply — landing it in the wrong OU is a real, common mistake). Support work here is largely **validation**, not architecture: confirm the account actually landed in the correct OU, confirm baseline logging/guardrails applied (they should, automatically, if Account Factory did the provisioning), and confirm the requesting team's Identity Center permission set was assigned to the new account so they can actually log into it.

## UC-8: Auditing "who can access which accounts" across a landing zone

**Problem**: security asks "list everyone who can access the Production account, and with what level of access" — a genuinely common landing-zone-scale question that per-account IAM tools can't answer alone, since access is centralized through Identity Center, not scattered IAM users.

**Implementation**: this is answered from the **Identity Center** side, not from IAM inside the target account — review permission set assignments (which users/groups → which permission sets → which accounts) rather than trying to enumerate IAM users inside Production itself, since in a properly run landing zone there mostly aren't any.

---

# PART 3 — HANDS-ON LABS (console, using our real account)

## LAB 1 — Audit what actually exists

1. **IAM console → Users** → click `ops-lab-cli` → **Permissions** tab. Confirm it shows `AdministratorAccess`.
2. Click the **Access Advisor** tab on that same user. Look at "Last accessed" per service — this is the real data you'd use to eventually tighten this down.
3. **IAM console → Roles** → click `ops-lab-ec2-ssm-role` → **Permissions** tab. You should see `AmazonSSMManagedInstanceCore`, `CloudWatchAgentServerPolicy`, and our custom inline `calculator-ssm-parameter-read` policy.
4. Click **Trust relationships** on that role. Confirm the trust policy names `ec2.amazonaws.com` as the trusted principal — this is what allows an *EC2 instance*, specifically, to assume this role, and nothing else.

## LAB 2 — Build and test the least-privilege ops-support role

1. Take the policy JSON from [iam-least-privilege-runbook.md](iam-least-privilege-runbook.md), replace the placeholder bucket ARN with a real one from our account (e.g., `calculator-ops-lab-flow-logs-967226343548`).
2. **IAM console → Roles → Create role** → trusted entity: **AWS account** (your own, for this test) → name it `cognizant-ops-support-role-test`.
3. Attach the policy as an inline policy.
4. **Test the positive case**:
```bash
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::967226343548:role/cognizant-ops-support-role-test --action-names ec2:StopInstances --resource-arns "*"
```
Expect `allowed`.
5. **Test the negative case** — this is the one that actually proves the guardrail works:
```bash
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::967226343548:role/cognizant-ops-support-role-test --action-names iam:CreateRole --resource-arns "*"
```
Expect `explicitDeny`.

## LAB 3 — Prove explicit Deny precedence, concretely

1. Create a throwaway test role with **two** policies attached: `AdministratorAccess` (a broad Allow) **and** a second inline policy containing only:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Deny",
    "Action": "ec2:TerminateInstances",
    "Resource": "*"
  }]
}
```
2. Run `simulate-principal-policy` for `ec2:TerminateInstances` against this role.
3. Confirm the result is `explicitDeny` — despite `AdministratorAccess` technically allowing everything, the narrower explicit Deny still wins. This is §1.3, proven rather than just stated.
4. Delete the test role afterward.

## LAB 4 — Turn on IAM Access Analyzer

1. **IAM console → Access Analyzer → Create analyzer**. Zone of trust: your own account. Create it.
2. Review any findings — in a solo lab account these will likely be minimal/none, but the exercise is knowing where this lives and what it's for.
3. Under **Policy validation**, paste the least-privilege policy from Lab 2 into the analyzer's policy checker before attaching it anywhere — this is the "validate before you deploy" habit from the JD's documentation/ownership language.

## LAB 5 — Generate and read the Credential Report

```bash
aws iam generate-credential-report
aws iam get-credential-report --query "Content" --output text | base64 -d
```
Review the output: access key age, MFA status, password last-used. In a real quarterly access review, this CSV is exactly what gets handed to a compliance team.

## LAB 6 — Enable IAM Identity Center and create a permission set (genuinely buildable with one account)

Full Control Tower/multi-account landing zone setup is out of scope for a solo lab (and isn't this role's actual job), but Identity Center itself works fine in a single-account "AWS account instance" mode, and this is the real mechanism from §1.12.

1. **IAM Identity Center console** → **Enable** (choose the account instance option if not part of an Organization)
2. **Users** → **Add user** → create a test user with your own email (you'll need to accept an invite)
3. **Permission sets** → **Create permission set** → **Predefined permission set** → choose `ReadOnlyAccess` → name it `cognizant-ops-readonly`
4. **AWS accounts** → select your account → **Assign users or groups** → pick your test user → assign the `cognizant-ops-readonly` permission set
5. Once provisioned, check the **IAM console → Roles** — you'll see a *new role* was auto-created there, named something like `AWSReservedSSO_cognizant-ops-readonly_...`. **This is the concrete proof of §1.12's claim**: Identity Center didn't invent a new access mechanism, it auto-provisioned a real IAM role and wires federated login to assume it.
6. Log in via the Identity Center **User portal URL** (shown on the Identity Center dashboard) as your test user, and confirm you land in the AWS console with read-only access — this is what a landing zone's actual human access flow looks like, end to end.

## LAB 7 — Set an account password policy (real, one settings page)

1. **IAM console → Account settings**
2. **Password policy → Edit**
3. Set: minimum length 14, require uppercase/lowercase/number/symbol, enable password expiration (e.g., 90 days), prevent password reuse (e.g., last 5)
4. **Save changes**

Quick to do, and a real setting an ops engineer might genuinely be asked to verify or tighten during a security review.

## LAB 8 — Cleanup

1. Delete `cognizant-ops-support-role-test` and the Lab 3 throwaway role
2. Leave the Access Analyzer running (no cost, ongoing value)
3. Remove the Identity Center test user/assignment if you don't want it lingering (or leave it — Identity Center itself has no cost)
4. **Do not touch `ops-lab-cli` or `ops-lab-ec2-ssm-role`** — both are still needed for the rest of the lab

---

# PART 4 — INTERVIEW QUESTIONS

## Fundamentals

**Q: What's the difference between an identity-based and a resource-based policy?**
Identity-based policies attach to a user, group, or role and define what that identity can do. Resource-based policies attach to the resource itself and define who can act on it — an S3 bucket policy is the clearest example. Resource-based policies are also the only mechanism that can grant access directly to a principal in a *different* AWS account, which is the actual mechanism behind cross-account AMI and S3 sharing.

**Q: Walk me through IAM's policy evaluation order.**
Everything starts implicitly denied. Then every applicable policy — identity-based, resource-based, permission boundary, and any Organization SCP — has to allow the action for it to succeed. But an explicit Deny anywhere in that stack overrides every Allow, regardless of which policy type it's in or how broad the Allow was.

**Q: When would you use a role instead of a user?**
Almost always, if the identity is a service, an application, or a temporary human session rather than a permanent individual credential. Roles issue short-lived credentials via STS rather than static access keys, which drastically reduces blast radius if something leaks. EC2 instances, Lambda functions, cross-account access, and SSO-federated humans should all use roles. Users with long-lived keys should be the exception, not the default.

**Q: What's a permission boundary, and how is it different from a Service Control Policy?**
Both act as a ceiling on maximum permissions, but at different scopes. A permission boundary is attached to a specific user or role and caps what that identity's own policies can ever grant, even if someone attaches a broader policy later — commonly used so a team can create their own roles without being able to escalate past an approved limit. An SCP is enforced at the AWS Organizations account or OU level, capping everything under that scope regardless of any individual identity's policy.

**Q: How would you investigate an unexpected Access Denied error?**
I'd use `simulate-principal-policy` to test the exact action and resource without trial-and-error against production. I'd specifically look for an explicit Deny somewhere other than the obvious attached policy — a permission boundary or an SCP can silently override an Allow that looks correct at first glance, and that's the case people usually miss.

**Q: What's the actual difference between Access Advisor and CloudTrail?**
CloudTrail is the complete, granular log of every API call made — who, what, when, source IP. Access Advisor is a summarized view derived from similar underlying data, but only at the service level — it tells you *whether* a role has used S3 recently, not the specific calls it made. I'd use Access Advisor to find unused permissions to remove, and CloudTrail for an actual forensic investigation.

## Scenario questions

**Q: An engineer says they can't perform an action that their attached policy clearly allows. What do you check?**
First I'd confirm I'm looking at *every* applicable policy, not just the one attached identity-based policy — a permission boundary or an Organization SCP could be silently capping it below what the identity policy grants, and neither shows up if you only read the one policy. I'd run `simulate-principal-policy` to get a definitive answer rather than guessing from reading JSON, and check explicitly for any Deny statement anywhere in the stack, since that always wins regardless of what else allows it.

**Q: How would you onboard a new team member with appropriate access, quickly but safely?**
I wouldn't hand-write a one-off policy for them — that doesn't scale and becomes unmanageable within a handful of hires. I'd add them to an existing group matching their role, or in a more mature environment, map them to an IAM Identity Center permission set rather than creating a raw IAM user at all. Either way, they get temporary or group-managed access rather than a bespoke long-lived credential.

**Q: You inherit an account where a service account has `AdministratorAccess`. How do you responsibly tighten it without breaking anything?**
I wouldn't just replace the policy and hope — I'd pull that identity's Access Advisor data first to see which services it's actually used and when, draft a scoped policy covering exactly that observed usage plus reasonable headroom, and validate it with the Access Analyzer's policy checker before attaching. I'd also test with `simulate-principal-policy` against the specific actions the real workflows need, ideally in a non-production copy of the role first, since replacing a working credential's permissions is a genuinely risky change if done blind.

**Q: How does cross-account resource sharing actually work under the hood?**
It depends on the resource type. For something like an AMI, it's a direct launch-permission grant naming the target account. For S3, it's a resource-based bucket policy naming the external account as a principal. For broader access — letting someone in another account operate as a role in yours — it's the AssumeRole pattern: a trust policy on the role names the external account as a trusted principal, the calling side runs `sts:AssumeRole`, and gets back temporary credentials scoped to whatever that role's permission policy allows.

## Landing zone / multi-account governance

**Q: What is an AWS Landing Zone, and what does it mean to operate "within" one rather than build one?**
A landing zone is a pre-architected, multi-account AWS environment — typically built with Control Tower or a Landing Zone Accelerator — that standardizes account structure, centralized logging, guardrails via SCPs at the OU level, and centralized human access via IAM Identity Center. Building one is a cloud foundations/platform team's job, done once. Operating within one — which is what an ops support role actually does — means requesting or validating new accounts land in the correct OU, managing access through Identity Center permission set assignments rather than per-account IAM users, and understanding that guardrails at the OU level can block an action even if the account's own IAM looks permissive.

**Q: A team says they can't perform an action in their AWS account even though their IAM role clearly allows it. What's different to check in a landing zone versus a single account?**
Beyond the account's own IAM (identity policy, resource policy, permission boundary), a landing zone adds a layer above the account entirely: Service Control Policies applied at the Organizational Unit the account sits in. An SCP denial doesn't show up anywhere in that account's own IAM console — you have to check the Organization's OU structure and its attached SCPs specifically, since that's a completely different console/permission surface than anything inside the account itself.

**Q: How is access typically granted to a new hire in a landing zone environment, versus a single-account setup?**
In a single account, you'd add them to an IAM group. In a landing zone, you almost never create an IAM user for a human at all — you assign them, via IAM Identity Center, a permission set against whichever specific accounts they need. Under the hood Identity Center auto-provisions the actual IAM role in each target account and federated login temporarily assumes it — so it's the same AssumeRole mechanism, just centrally managed across every account in the org instead of configured per account.

**Q: What's your role in "supporting AWS account creation" if you're not the one architecting the landing zone?**
It's primarily validation, not design: confirming a new account request lands in the correct OU (since that single choice determines which guardrails automatically apply), confirming the baseline logging/security configuration actually took effect if Account Factory provisioned it, and confirming the requesting team's Identity Center access was assigned so they can actually log in — not designing the account structure itself.

---

# PART 5 — QUICK REFERENCE

## Policy evaluation cheat sheet

1. Default: **implicit deny**
2. All applicable policy types (identity, resource, boundary, SCP) must allow
3. **Explicit Deny always wins**, anywhere in the stack

## Users vs. Roles cheat sheet

| Use case | Use |
|---|---|
| EC2 instance needing AWS API access | Role (instance profile) |
| Lambda function | Role (execution role) |
| Cross-account access | Role (AssumeRole) |
| SSO/federated human | Role (via Identity Center) |
| Long-lived automation with no role option | User (last resort, rotate keys) |

## Single account vs. landing zone cheat sheet

| Question | Single account | Landing zone |
|---|---|---|
| Where does human access live? | IAM users/groups | IAM Identity Center permission set assignments |
| What can silently block an allowed action? | A Deny elsewhere in the account's own policies | The above, **plus** an SCP at the OU level — invisible from inside the account |
| How is a new account provisioned? | N/A (it just exists) | Organizations/Control Tower Account Factory, landed in a specific OU |
| Underlying access mechanism | Direct policy attachment | Still AssumeRole under the hood — just centrally provisioned |

## Common mistakes to avoid (and to mention when asked)

1. Using a long-lived user with access keys when a role would work instead
2. Reading only the one obvious attached policy and missing a Deny elsewhere (permission boundary, SCP)
3. Hand-crafting a one-off policy per person instead of using groups
4. Using S3 ACLs instead of bucket policies for cross-account sharing
5. Never checking Access Advisor before "temporarily" granting broad access that becomes permanent
6. Forgetting MFA on the root account
7. A role that can modify its own IAM policy — a privilege-escalation path
8. Troubleshooting an access-denied issue only inside the account's own IAM, missing an OU-level SCP that's actually the real blocker
9. Landing a new account in the wrong OU during provisioning, silently giving it the wrong guardrails
8. Treating IAM as a one-time setup instead of an ongoing least-privilege tightening process

## Study sequence

| Session | Labs | Focus |
|---|---|---|
| 1 | 1 | Audit our real account's existing IAM state |
| 2 | 2 | Build and test the least-privilege ops-support role |
| 3 | 3 | Prove explicit Deny precedence concretely |
| 4 | 4, 5 | Access Analyzer + Credential Report |
| 5 | 6, 7 | Identity Center + permission set (the real landing-zone access mechanism), password policy |
| 6 | 8 | Cleanup |
| 7 | — | Answer every Part 4 question out loud, including the landing zone section |
