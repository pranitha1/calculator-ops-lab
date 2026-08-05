# Runbook: SSL Certificate Request → ACM → Load Balancer

Covers the end-to-end flow when a certificate comes from an internal PKI team
or external CA (not an AWS-issued ACM certificate with auto-renewal).

## Step 1 — Generate the CSR and key yourself (don't let the CA generate your key)

```bash
openssl req -new -newkey rsa:2048 -nodes \
  -keyout domain.key \
  -out domain.csr \
  -subj "/CN=app.example.com" \
  -addext "subjectAltName=DNS:app.example.com,DNS:www.example.com"
```

- `-nodes` = key is generated unencrypted, since you're keeping it yourself and never transmitting it
- Best practice: the private key never leaves your possession. You send the CA/PKI team only the **CSR** (public info + signing request) — never the key.
- In practice (like your Syngenta case), some internal PKI teams generate the key themselves and hand it to you along with the cert. That's less ideal (the key touched another system/person before you), but common in enterprises — hence needing the decrypt/verify steps below.

## Step 2 — Submit the request

Via ticketing system / internal PKI portal, typically need to specify:
- Domain name(s) / SANs
- Cert type (single-domain, wildcard, multi-SAN)
- Environment (prod / non-prod)
- Validity period
- Business/change justification, approver

## Step 3 — Receive the response

Typically arrives as up to 3 files:
1. **Domain (leaf) certificate** — `.crt` / `.pem` — the cert for your specific domain
2. **Certificate chain** — `.pem` / `.crt` bundle — intermediate CA cert(s) linking yours to a trusted root
3. **Private key** — `.key` / `.pem` — only if the PKI team generated the key (skip if you generated your own in Step 1). Usually password-protected in transit; the passphrase should arrive via a **separate channel** (call, separate message, password manager) — never bundled with the key file itself.

All of these are PEM/X.509 text format regardless of extension — never PPK (that's SSH-only, unrelated).

## Step 4 — Verify what you received

```bash
# Inspect the cert: CN/SAN, issuer, validity window
openssl x509 -in domain.crt -noout -text | grep -A2 "Subject:\|Validity\|DNS:"

# If a chain was provided, verify it actually validates against the cert
openssl verify -CAfile chain.pem domain.crt
```

## Step 5 — Decrypt the key, if it was provided encrypted

```bash
# Standalone encrypted PEM key
openssl pkey -in encrypted_key.pem -out domain.key
# (prompts for passphrase interactively — never pass it as a CLI flag)

# OR combined PKCS#12 bundle
openssl pkcs12 -in bundle.pfx -nocerts -nodes -out domain.key
openssl pkcs12 -in bundle.pfx -clcerts -nokeys -out domain.crt
openssl pkcs12 -in bundle.pfx -cacerts -nokeys -chain -out chain.pem
```

**Always verify the key matches the cert before proceeding** — a mismatched pair
is a common real incident:
```bash
openssl x509 -noout -modulus -in domain.crt | openssl md5
openssl rsa  -noout -modulus -in domain.key | openssl md5
# both hashes must match
```

## Step 6 — Import into ACM

```bash
aws acm import-certificate \
  --certificate fileb://domain.crt \
  --certificate-chain fileb://chain.pem \
  --private-key fileb://domain.key \
  --region us-east-1
```
(or ACM console → Import a certificate, pasting each file's contents into its box)

## Step 7 — Attach to the load balancer

Update the HTTPS listener (port 443) on the ALB/NLB to use the new certificate
ARN. If replacing an expiring cert on a listener already in use, this is a
zero-downtime swap — the listener picks up the new cert immediately without
dropping connections.

## Step 8 — Verify end to end

```bash
curl -v https://app.example.com/health

# Confirm the cert actually being served matches what you imported
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

For internet-facing prod certs, also worth running an SSL Labs scan for
protocol/cipher grade.

## Step 9 — Clean up and document

- Delete plaintext decrypted key files from wherever you staged them
- Confirm nothing was committed to source control
- Update the change ticket: what cert, which listener, expiry date, rollback plan

## Step 10 — Track renewal (the part people forget)

**Critical gotcha:** ACM only auto-renews certificates it *issued itself* via
DNS validation on a domain delegated to it. **Imported certificates (from a
PKI team or external CA) never auto-renew** — ACM will silently let them
expire unless you track it yourself. An expired cert on a listener = a
production outage that looks like "the app is down" but is actually a
cert lifecycle miss.

Mitigation:
```bash
aws acm describe-certificate --certificate-arn <arn> --query "Certificate.NotAfter"
```
Set a CloudWatch alarm or calendar reminder well before that date (30-60 days
out is typical, since CA reissuance + internal approval can itself take
1-2 weeks).
