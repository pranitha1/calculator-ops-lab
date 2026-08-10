# Terraform Fundamentals — Notes

Living document — appended to as we cover more. All examples are pulled from
our own real file: `v3-vpc-logging-dns/main.tf`, not invented examples.

**Method**: each topic below is explained just-in-time, immediately
implemented against real code, immediately verified, immediately noted —
never a big reading block before touching anything. This index exists purely
for visibility into the full journey, not as a read-first reference.

## Index

1. ✅ Core fundamentals — blocks, provider, resource vs data, references, `depends_on`, `output`
2. ✅ State — what it is, why it exists, why losing it is dangerous, locking
3. ✅ Practical mechanics — where to write code, the four commands, the day-to-day loop
4. ✅ Variables & `.tfvars` — converted `region` from hardcoded to `var.region`, ran `plan`/`apply` for real, confirmed zero unintended changes. Bonus real result: the same `apply` also fixed a genuine long-pending bug (S3 flow-log lifecycle was still set to delete after 30 days instead of archiving to Glacier — fixed in code weeks ago, never actually applied until now)
5. ⬜ Locals — computed/derived values reused across a config
6. ⬜ `count` & `for_each` — creating multiple resources without copy-pasting blocks
7. ⬜ Conditional expressions
8. ⬜ Remote backend — S3 + DynamoDB locking, hands-on migration
9. ⬜ Modules — packaging a reusable pattern
10. ⬜ `terraform import` — bringing already-existing infrastructure under Terraform control (directly relevant — we have real infra that was partly built by hand)
11. ⬜ Workspaces — managing multiple environments from one config
12. ⬜ Full destroy → apply cycle, timed
13. ✅ GitHub Actions OIDC federation — built for real via Terraform (`github-oidc/main.tf`): `tls_certificate` data source, `aws_iam_openid_connect_provider`, a trust policy scoped to `repo:pranitha1/calculator-ops-lab:*`. Applied cleanly, 3 resources, real role ARN: `arn:aws:iam::967226343548:role/github-actions-calculator-ops-lab`

---

## 1. The core idea: declarative, not a script

Terraform describes the **end state you want**, not the steps to get there.
A Bash script says "step 1: create a bucket, step 2: enable encryption."
Terraform says "here is what should exist" — it figures out what actions are
needed to make reality match that description, including the correct order.

## 2. The `terraform` block — config about Terraform itself

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```
Not a resource. Terraform has zero built-in knowledge of AWS — it talks to
clouds/services through **providers**, which are plugins. This block declares
which plugin(s) this project needs and which version range is acceptable.

## 3. The `provider` block — configuring that plugin

```hcl
provider "aws" {
  region = "us-east-1"
}
```
Sets options for the plugin declared above — here, which AWS region it
operates in. Every resource below inherits this unless told otherwise.

## 4. `data` blocks — read, never create

```hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_caller_identity" "current" {}
```
A `data` block is a **lookup**. It finds something that *already exists* and
lets you reference its properties. Terraform never creates, modifies, or
destroys anything described in a `data` block — it only reads. Example use:
`data.aws_caller_identity.current.account_id` fetches your real account ID
live, instead of it being hardcoded somewhere.

## 5. `resource` blocks — create and manage

```hcl
resource "aws_s3_bucket" "flow_logs" {
  bucket = "calculator-ops-lab-flow-logs-${data.aws_caller_identity.current.account_id}"
}
```
The anatomy, and it repeats everywhere:
```
resource "<TYPE>" "<YOUR OWN LOCAL NAME>" { arguments }
```
- **TYPE** (`aws_s3_bucket`) comes from the provider plugin — you don't invent these, they come from the provider's documentation
- **LOCAL NAME** (`flow_logs`) is chosen by you, used only to refer to this resource elsewhere in your own code — it is *not* the resource's real AWS name (that's the `bucket = "..."` argument inside)

Unlike `data`: a `resource` block means Terraform **owns** this thing. Delete
the block and run `apply` again, and Terraform will destroy the real object.

## 6. References between blocks = the dependency graph

```hcl
resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  ...
}
```
`aws_s3_bucket.flow_logs.id` says "use the ID of the bucket resource defined
above." Terraform reads every reference like this across the whole file to
build a **dependency graph** — it now knows the public-access-block can't be
created until the bucket exists, and creates things in the correct order
automatically. You never write "do this after that" — it's inferred from
what each resource actually references.

## 7. `depends_on` — for when there's no natural reference to infer order from

```hcl
resource "aws_flow_log" "default_vpc" {
  ...
  depends_on = [aws_s3_bucket_policy.flow_logs]
}
```
The flow log doesn't reference the bucket policy in any of its own arguments
— but it still needs that policy to exist first (AWS requires the delivery
permission be in place before flow logs can start writing). Since there's no
argument-level reference for Terraform to infer this from, `depends_on`
states the ordering requirement explicitly. **This is the exception, not the
norm** — most ordering happens automatically via §6.

## 8. `output` blocks — getting information back out

```hcl
output "flow_logs_bucket" {
  value = aws_s3_bucket.flow_logs.id
}
```
Printed to the terminal after `apply` finishes. How you surface a value you
need afterward — we used this pattern to grab the ALB's DNS name in v4.

---

## 9. State — what `terraform.tfstate` actually is

Real excerpt from our own `v3-vpc-logging-dns/terraform.tfstate`:
```json
{
  "mode": "data",
  "type": "aws_caller_identity",
  "name": "current",
  "instances": [{
    "attributes": {
      "account_id": "967226343548",
      "arn": "arn:aws:iam::967226343548:user/ops-lab-cli",
      ...
```
State is a JSON file Terraform keeps as its own record of every resource it
manages, plus the **real, current values** of every attribute on each one.
That's the exact `data "aws_caller_identity" "current" {}` block from the
code — and underneath it, the actual real values it resolved to. **State is
not a copy of your code — it's a cache of what your code resolved to in the
real world.**

**Why it has to exist**: `"flow_logs"` in `resource "aws_s3_bucket" "flow_logs"`
is a name *you* made up — it has no inherent link to any real AWS object.
State is the dictionary mapping "your local name" → "the actual AWS resource
ID and every attribute AWS reports for it." Without it, Terraform has no way
to know which real object, if any, corresponds to a block in your code. It
also means `plan` only has to check *its own* tracked resources instead of
scanning your whole account every time.

## 10. The plan → apply cycle, precisely

`plan` does three things: (1) reads the state file, (2) **refreshes** — calls
the real AWS APIs to check whether reality still matches what state recorded,
(3) compares that against what your *code* says should exist, and shows the
diff. `apply` executes that diff.

**This is exactly what happened in our real security-group drift incident.**
When `plan` ran, step 2's refresh discovered the *live* security group rule
no longer matched what the code described — someone had changed it manually,
outside Terraform. That mismatch is what produced the "wants to revert this"
diff. That wasn't a bug — it was the refresh-then-diff mechanism working
exactly as designed, on a change we didn't want reverted.

## 11. Why losing state is genuinely dangerous

If the state file is gone, Terraform has no memory that
`aws_s3_bucket.flow_logs` maps to a real, already-existing bucket. Run
`apply` again, and Terraform thinks nothing exists yet — it tries to
**create** a new one. That either fails outright (S3 bucket names are
globally unique) or, worse, succeeds — leaving the original real bucket
sitting in AWS, still costing money, completely orphaned and untracked. This
is the core reason a remote backend (S3, not a single laptop file) matters.

## 12. State locking, briefly

If two `apply` runs happened at the same moment against the same state, both
could read the same stale state, calculate different changes, and write
conflicting results — corrupting the file or the real infrastructure. A
**lock** (a DynamoDB table, in the standard S3-backend pattern) forces the
second run to wait rather than proceed blindly on stale information.

---

## 13. The practical mechanics — where you write code, and how "deploy" works

This is the missing piece between understanding the concepts and actually
doing it — how do you physically write and run this stuff.

**Where you write code**: a `.tf` file is just a plain text file. You edit it
with any text editor — Notepad works, but the real tool most engineers use
is **VS Code** with the free "HashiCorp Terraform" extension installed, which
gives you syntax highlighting and catches obvious typos as you type. Nothing
fancier than that is required to start.

**File layout convention** (not a hard requirement — Terraform reads *every*
`.tf` file in a directory and treats them as one combined configuration,
regardless of filename): by convention, larger projects split things into
`main.tf` (resources), `variables.tf` (variable declarations),
`outputs.tf` (output declarations). Our project so far keeps everything in
one `main.tf` per stack — that's fine at this size, and you don't need to
split files until it actually gets unwieldy.

**Where you run commands**: in a terminal (PowerShell or Bash), navigated
(`cd`) into the specific folder containing the `.tf` files you want to act
on. Each folder with its own `.tf` files + state is an independent unit —
this is why our project has separate folders (`v2-rds-terraform`,
`v3-vpc-logging-dns`, etc.) instead of one giant file for everything.

**The four commands, in the order you actually use them:**

1. **`terraform init`** — run once when you start a new project, or anytime
   you add/change a provider or backend configuration. Downloads the
   provider plugins (the AWS plugin, etc.) into a local `.terraform/`
   folder. You'll know you need this again if a command errors about a
   missing provider.
2. **`terraform plan`** — the **preview**. Reads your code, reads state,
   refreshes against real AWS, shows you the diff. **Touches nothing real.**
   Safe to run as often as you want.
3. **`terraform apply`** — the **actual deploy step**. There is no separate
   "deploy" command in Terraform — `apply` *is* deploying. It re-runs the
   same comparison as `plan`, shows you the diff again, and asks
   `Do you want to perform these actions? Enter a value:` — type `yes` to
   confirm, and it executes.
4. **`terraform destroy`** — tears down every real resource this specific
   folder's state is tracking. Also shows a diff and asks for `yes` first.

**The actual day-to-day loop**:
edit a `.tf` file in your text editor and save it → switch to the terminal →
`terraform plan` → read the diff carefully → if it's what you expect,
`terraform apply` → type `yes` → done. That's the entire cycle, every time,
for every change, forever — there's nothing more to it mechanically than
that loop repeated.

---

## Still to cover (next sessions, append below as we go)

- **Variables** (`variable` blocks) and why hardcoded values like our region/account references should eventually become configurable
- **Remote backend** (S3 + DynamoDB locking) — the actual migration, hands-on
- **Modules** — packaging a reusable pattern (candidate: the S3-bucket-with-lifecycle-and-policy pattern from this same file)

## Comprehension check before moving on

Confirmed understood: `resource` vs `data` distinction; ordering comes from
references (the dependency graph) not file order; state is a real-value
cache + name-to-ID map, not a copy of code; the drift incident was the
refresh-then-diff mechanism working as intended.
