# TLS Certificate Reference

> **Purpose**: How TLS works in this deployment, why each piece exists, and how it differs between local dev (self-signed) and production (real CA-signed). Read this when you need to renew a cert, debug a cert error, or set up TLS in a new environment.

---

## Table of Contents

1. [TLS in 60 Seconds](#tls-in-60-seconds)
2. [What a Certificate Actually Is](#what-a-certificate-actually-is)
3. [The Trust Chain](#the-trust-chain)
4. [Self-Signed Certificates (Dev)](#self-signed-certificates-dev)
5. [The Self-Signed Setup Walkthrough](#the-self-signed-setup-walkthrough)
6. [Why Browsers Warn About Self-Signed](#why-browsers-warn-about-self-signed)
7. [Production TLS — Real CAs](#production-tls--real-cas)
8. [Let's Encrypt with cert-manager](#lets-encrypt-with-cert-manager)
9. [AWS ACM for EKS](#aws-acm-for-eks)
10. [Comparing Dev and Prod Side by Side](#comparing-dev-and-prod-side-by-side)
11. [Certificate Lifecycle Operations](#certificate-lifecycle-operations)
12. [Common Issues and Their Causes](#common-issues-and-their-causes)

---

## TLS in 60 Seconds

When you visit `https://auth.local`, three things happen:

1. **Server proves identity** — sends a certificate that says "I am auth.local"
2. **Client verifies the cert** — checks if a trusted authority signed it
3. **They establish encryption** — key exchange protects all further traffic

The certificate is just a file. The trust comes from **who signed it**. Browsers ship with a list of trusted Certificate Authorities (CAs); anything signed by those is trusted automatically.

Self-signed certs are signed by themselves (no CA involved). Browsers can't verify them, so they warn. Production certs are signed by real CAs that browsers already trust, so no warnings.

---

## What a Certificate Actually Is

A TLS certificate is a small file containing structured data. The most important fields:

```
Subject:        CN=auth.local, O=auth-local
Issuer:         CN=auth.local, O=auth-local        ← self-signed: same as Subject
Valid From:     2026-06-01 00:00:00
Valid Until:    2027-06-01 00:00:00
Public Key:     <2048-bit RSA key>
Extensions:
    Subject Alternative Name: DNS:auth.local
Signature:      <bytes signed with the issuer's private key>
```

What each field means:

| Field | Purpose |
|---|---|
| **Subject** | Who this cert belongs to (which hostname) |
| **Issuer** | Who signed this cert (a CA, or yourself for self-signed) |
| **Valid From/Until** | The cert's lifetime — outside this window, browsers reject |
| **Public Key** | One half of the asymmetric keypair; used to negotiate session keys |
| **Subject Alternative Name (SAN)** | Modern browsers require this; lists valid hostnames |
| **Signature** | Cryptographic proof that the Issuer's private key signed this cert |

The matching **private key** is a separate file that stays on the server. The cert (public part) is what browsers see; the key (private part) lets the server prove it owns the cert.

If anyone gets your private key, they can impersonate your server. That's why the key file is the most sensitive thing in this whole system.

---

## The Trust Chain

When a browser sees a certificate, it doesn't just trust it because of the contents. It traces a chain back to something it already trusts.

```
End-entity cert (auth.example.com)
        │
        │ "Signed by..."
        ▼
Intermediate CA (Let's Encrypt R3)
        │
        │ "Signed by..."
        ▼
Root CA (ISRG Root X1)
        │
        │ Pre-installed in browser
        ▼
TRUSTED ✓
```

The browser:
1. Receives your end-entity cert
2. Checks who signed it (the Issuer field)
3. Looks at the next cert up the chain (often sent alongside the leaf cert)
4. Repeats until it hits a cert it already trusts (a Root CA in its trust store)

If the chain leads to a known Root CA → trusted. If not → warning.

### Where the Trust Store Lives

Different systems, different trust stores:

| System | Trust store location |
|---|---|
| macOS | Keychain Access app — System Roots |
| Linux | `/etc/ssl/certs/ca-certificates.crt` |
| Windows | Certificate Manager (`certmgr.msc`) |
| Firefox | Its own bundled list (ignores OS) |
| Chrome on Mac | Uses macOS Keychain |
| Java | `cacerts` file in the JRE |
| curl | Its own bundle, or system bundle |

This is why a cert that "works" in one tool sometimes fails in another — they may consult different trust stores.

---

## Self-Signed Certificates (Dev)

A self-signed cert is one where the Issuer is the same as the Subject. You sign your own cert with your own private key. There's no third-party validation.

```
auth.local cert
        │
        │ "Signed by..."
        ▼
auth.local (itself)
        │
        │ Not in any browser's trust store
        ▼
WARNING ⚠
```

This is fine for dev because:
- You control both the server and the client (your laptop)
- You know the cert is legitimate because you generated it
- You can explicitly tell your browser "trust this one"

It's NOT fine for production because:
- Your users would see warnings → they'd assume the site is compromised
- They'd be trained to ignore warnings, defeating the warning's purpose
- A malicious actor could trivially impersonate your service

### When Self-Signed Is Acceptable

- Local development environments (your laptop, your minikube)
- Internal-only services with controlled clients (e.g., a service that only your CI pipeline calls)
- Testing TLS configuration without committing to a real CA setup

### When Self-Signed Is NOT Acceptable

- Anything users will see in a browser
- Anything mobile apps connect to (they often refuse self-signed entirely)
- Anything regulated (PCI, HIPAA, SOC 2 may explicitly require CA-signed certs)
- Any service you'd be embarrassed to explain to your security team

---

## The Self-Signed Setup Walkthrough

Here's exactly what we did for minikube, with the reasoning behind each step.

### Step 1: Generate the Cert and Key

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /tmp/auth-tls.key \
  -out /tmp/auth-tls.crt \
  -subj "/CN=auth.local/O=auth-local" \
  -addext "subjectAltName = DNS:auth.local"
```

Breaking this down:

| Flag | Meaning |
|---|---|
| `openssl req` | Subcommand for certificate requests |
| `-x509` | Self-signed mode (not a request to send to a CA) |
| `-nodes` | "No DES" — don't encrypt the private key with a password |
| `-days 365` | Cert valid for 1 year |
| `-newkey rsa:2048` | Generate a new 2048-bit RSA keypair |
| `-keyout <file>` | Write the private key here |
| `-out <file>` | Write the certificate here |
| `-subj "/CN=..."` | Set the Subject field non-interactively |
| `-addext "subjectAltName=..."` | Add the Subject Alternative Name extension |

After running, you have:
- `/tmp/auth-tls.key` — the private key (PEM-encoded, ~1700 bytes)
- `/tmp/auth-tls.crt` — the certificate (PEM-encoded, ~1300 bytes)

#### Why `-nodes`

Without `-nodes`, OpenSSL would encrypt the private key with a password you'd type. Every time the server starts, it would need that password. For a Kubernetes Secret, that's not workable — the controller can't type passwords. So we leave the key unencrypted.

The risk: anyone with the key file can impersonate your service. In dev that's fine (the key lives only in your local etcd). In production you'd use a hardware HSM or cloud KMS to protect the key, but that's a much larger discussion.

#### Why `-days 365`

Modern browsers reject certs valid for more than ~398 days. Setting 365 keeps you well under the limit and gives you a yearly renewal cadence. For dev where the cluster is ephemeral, the duration barely matters.

#### Why `-newkey rsa:2048`

2048-bit RSA is the current floor for browser acceptance. 4096-bit RSA is more secure but ~5x slower at handshake. ECDSA (`-newkey ec:<curve>`) is faster and smaller but slightly less universally supported. For dev, 2048 RSA is the safe default.

#### Why the SAN Extension

Browsers used to validate certs against the Subject's Common Name (CN). Modern browsers ignore CN entirely and require a Subject Alternative Name (SAN) extension matching the hostname. Without the SAN, Chrome and Firefox will fully refuse the connection — not even a "click to proceed" option.

The `-addext "subjectAltName = DNS:auth.local"` adds this required field.

For multiple hostnames or wildcards:
```bash
-addext "subjectAltName = DNS:auth.local,DNS:*.auth.local,DNS:api.local"
```

### Step 2: Create the Kubernetes Secret

```bash
kubectl create secret tls auth-tls \
  --cert=/tmp/auth-tls.crt \
  --key=/tmp/auth-tls.key \
  --namespace=auth-service
```

This creates a Secret of type `kubernetes.io/tls` with two fields: `tls.crt` and `tls.key`.

The Secret looks like (don't run, just for understanding):

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: auth-tls
  namespace: auth-service
data:
  tls.crt: LS0tLS1CRUdJTi...   # base64-encoded cert
  tls.key: LS0tLS1CRUdJTi...   # base64-encoded key
```

#### Why `kubernetes.io/tls` Type Specifically

Kubernetes has several Secret types. The `tls` type is structurally identical to `Opaque` but signals intent and enforces the two-key format. Tools that consume TLS data (NGINX Ingress, cert-manager) expect this type.

If you accidentally use `--type=Opaque` instead, NGINX Ingress will reject the Secret silently and fall back to a self-generated cert (making the warning even worse).

#### Why Same Namespace

Kubernetes Secrets are namespace-scoped. The Ingress in `auth-service` namespace can only reference Secrets in the **same** namespace. A common mistake is creating the Secret in `default`:

```bash
# WRONG (creates in 'default' namespace)
kubectl create secret tls auth-tls --cert=... --key=...

# RIGHT (creates in auth-service namespace)
kubectl create secret tls auth-tls --cert=... --key=... --namespace=auth-service
```

The Ingress would silently fail to find the Secret.

### Step 3: Delete the Local Files

```bash
rm /tmp/auth-tls.crt /tmp/auth-tls.key
```

The Secret in etcd is now the single source of truth. Local files are unnecessary and pose a leak risk if accidentally committed or backed up. `/tmp` is auto-cleaned on macOS reboot, but explicit deletion is safer.

### Step 4: Reference From the Ingress

The Ingress YAML references the Secret by name:

```yaml
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - auth.local
      secretName: auth-tls       # Must match the Secret's metadata.name
  rules:
    - host: auth.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: auth-service
                port:
                  number: 8081
```

When the Ingress controller (NGINX) sees this Ingress, it:
1. Looks up the Secret named `auth-tls` in the same namespace
2. Loads `tls.crt` and `tls.key` from it
3. Configures itself to terminate TLS for `auth.local` using that keypair

If the Secret changes (cert renewal), NGINX detects this and reloads automatically.

---

## Why Browsers Warn About Self-Signed

When you visit `https://auth.local`, your browser:

1. Receives the cert from NGINX
2. Reads the Issuer field → "auth.local" (yourself)
3. Looks for "auth.local" in the trusted CA list → not there
4. Cannot verify the chain → shows warning

The warning is technically correct. The browser has no way to know if your self-signed cert is legitimate or a man-in-the-middle attack. Only you (who generated it) know it's legitimate.

The "Advanced → Proceed" override tells the browser "I trust this cert for this hostname; remember my choice." After clicking, the cert is added to a per-site exception list (browser-scoped, not OS-wide).

### Making the Warning Go Away Permanently (Optional)

You can add the cert to your macOS Keychain, which makes the warning disappear in Safari and Chrome (Firefox uses its own store and would still warn).

```bash
# Export cert from K8s Secret to a file
kubectl get secret auth-tls -n auth-service \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/auth-local.crt

# Add to system trust store (macOS)
sudo security add-trusted-cert -d \
  -r trustRoot \
  -k /Library/Keychains/System.keychain \
  /tmp/auth-local.crt

# Cleanup
rm /tmp/auth-local.crt
```

After this, Chrome/Safari trust the cert without warnings. Firefox would still warn.

**To undo**, open Keychain Access → System → find "auth.local" → delete.

For dev, the warning override is usually fine. Add to keychain only if you're doing browser-based testing and the warnings are friction.

---

## Production TLS — Real CAs

In production, you use a certificate signed by a real Certificate Authority that browsers already trust. No warnings, automatic validation.

### How a Real Cert Is Different

```
auth.example.com cert
        │ 
        │ Issuer: R3 (Let's Encrypt intermediate)
        ▼
R3 cert
        │
        │ Issuer: ISRG Root X1 (Let's Encrypt root)
        ▼
ISRG Root X1
        │
        │ Pre-installed in browser
        ▼
TRUSTED ✓
```

The cert says "I am auth.example.com." It's signed by an intermediate CA, which is signed by a root CA, which is in every browser's trust store. Chain validates → no warning.

### What "Signed By A Real CA" Means

A real CA (Let's Encrypt, DigiCert, Sectigo, AWS) issues a certificate after **proving** you control the domain. The process:

1. **You generate a keypair** (private key stays with you, never leaves your control)
2. **You generate a Certificate Signing Request (CSR)** containing your public key and the domains you want
3. **You prove domain control** — typically by putting a specific value in DNS (DNS-01) or serving a specific file at a URL (HTTP-01)
4. **The CA verifies** the challenge
5. **The CA signs your CSR** with their private key
6. **You get the signed certificate** and deploy it

The CA never sees your private key. They only sign your CSR after proving you control the domain.

### Why Not Just Use Self-Signed in Production?

- Users would see browser warnings → site appears compromised
- Mobile apps often refuse self-signed entirely
- Some clients (curl, Java HttpClient, browsers in strict mode) fail rather than warn
- It signals operational immaturity to security-conscious users

The cost of "doing it right" is nearly zero today (Let's Encrypt is free, automated). There's no reason to use self-signed publicly.

---

## Let's Encrypt with cert-manager

Let's Encrypt is a free, automated CA. Combined with cert-manager (a Kubernetes operator), you get fully automatic cert issuance and renewal.

### How It Works

```
You create a Certificate resource in K8s
        ↓
cert-manager sees it
        ↓
cert-manager generates a private key
        ↓
cert-manager creates a CSR
        ↓
cert-manager talks to Let's Encrypt API
        ↓
Let's Encrypt issues a challenge:
   "Prove you control auth.example.com.
   Put this token at http://auth.example.com/.well-known/acme-challenge/..."
        ↓
cert-manager configures NGINX to serve the token
        ↓
Let's Encrypt fetches it, verifies
        ↓
Let's Encrypt signs the CSR
        ↓
cert-manager stores the signed cert as a Kubernetes Secret
        ↓
Ingress uses the Secret (same shape as our self-signed setup!)
```

The Ingress doesn't know if the cert is self-signed or from Let's Encrypt. It just references a Secret. The **only** difference is who created the Secret — manually for self-signed, automatically for cert-manager.

### Setup Sketch

Installation:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

Define a ClusterIssuer pointing at Let's Encrypt:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
```

Then in your Ingress, add an annotation to trigger auto-issuance:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - auth.example.com
      secretName: auth-tls-prod      # cert-manager creates this
  rules:
    - host: auth.example.com
      # ...
```

cert-manager watches Ingresses with this annotation, issues the cert, and creates the Secret automatically. The Ingress then uses it. Renewals happen automatically before expiry.

### Renewal

Let's Encrypt certs are valid for 90 days. cert-manager automatically renews them ~30 days before expiry. No manual intervention. The Secret content updates in place, NGINX detects the change and reloads.

### What Makes This Powerful

- Free certs from a real CA
- Fully automated issuance + renewal
- Same shape as self-signed (Secret with tls.crt and tls.key)
- Works for any internet-reachable domain
- Trusted by all browsers

Once set up, you forget about TLS until the next cluster rebuild.

### Limitations

- Domain must be internet-reachable for HTTP-01 challenge (or you use DNS-01 with API access to your DNS)
- Doesn't work for `.local` domains (Let's Encrypt only issues for real, internet-reachable domains)
- Rate limits (50 certs per registered domain per week — generous, but exists)

---

## AWS ACM for EKS

If you're on AWS, ACM (AWS Certificate Manager) is even simpler than cert-manager. It's the standard approach for EKS.

### How It Differs

- ACM issues certs you can use with AWS services (ALB, CloudFront, API Gateway)
- ACM does NOT export private keys — you can't run ACM certs on a generic server, only on AWS-managed endpoints
- Domain validation via DNS (CNAME records in Route 53) — automated if Route 53 is your DNS

### The EKS Flow

```
1. Request cert in ACM console (or Terraform):
     Domain: auth.example.com
     Validation: DNS

2. ACM gives you a CNAME record to add to DNS
3. Route 53 has API → auto-add the record (if Route 53 manages the domain)
4. ACM verifies, issues cert, gives you an ARN:
     arn:aws:acm:us-east-1:123456789012:certificate/abc-def

5. In your Kubernetes Ingress (using AWS Load Balancer Controller):

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:...:certificate/abc-def
spec:
  rules:
    - host: auth.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: auth-service
                port:
                  number: 8081
```

Notice: no Secret reference for TLS. Instead, the ALB references the ACM cert ARN directly. The ALB Controller in your cluster reads the annotation, creates an ALB in AWS, and configures the ALB to use the ACM cert.

### Renewal

ACM auto-renews certs ~60 days before expiry. The ALB picks up the new cert automatically. No action needed.

### Why ACM Is Often Better Than Let's Encrypt on AWS

- Tighter AWS integration
- No need to run cert-manager
- ACM-issued certs can be used on ALB, CloudFront, API Gateway uniformly
- Built-in renewal with no ops involvement

The trade-off: ACM certs only work with AWS-managed endpoints. If you have generic Kubernetes Services that need their own TLS, cert-manager is still the right choice.

---

## Comparing Dev and Prod Side by Side

| Concern | Dev (minikube) | Prod (EKS with ACM) | Prod (Any K8s with cert-manager) |
|---|---|---|---|
| Cert source | openssl on your laptop | AWS ACM | Let's Encrypt |
| Cost | Free | Free | Free |
| Browser warnings | Yes (self-signed) | None | None |
| Cert valid | 1 year | 13 months | 90 days |
| Renewal | Manual | Auto (ACM) | Auto (cert-manager) |
| Stored in K8s as | Secret (kubernetes.io/tls) | Not in K8s — ALB references ACM ARN | Secret (kubernetes.io/tls) |
| Created by | You manually | AWS automatically | cert-manager automatically |
| Setup complexity | 4 commands | One-time ACM request | One-time cert-manager install |
| Multi-hostname | Re-run openssl with multiple SANs | Multiple ARNs or wildcard | Update Ingress spec |
| Wildcard support | Yes, via SAN | Yes | DNS-01 challenge required |

### The Important Realization

The **Ingress YAML for self-signed dev and Let's Encrypt prod is nearly identical**. Same `tls:` block, same Secret reference. The cert source is invisible to the Ingress.

For ACM/ALB, the Ingress is structurally different (no Secret reference, ARN annotation instead). This is the bigger conceptual jump.

---

## Certificate Lifecycle Operations

### Inspecting a Cert

From a file:

```bash
openssl x509 -in /path/to/cert.crt -text -noout | head -30
```

From a Kubernetes Secret:

```bash
kubectl get secret auth-tls -n auth-service \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -text -noout | head -30
```

From a live server:

```bash
openssl s_client -showcerts -connect auth.local:443 -servername auth.local < /dev/null 2>/dev/null | \
  openssl x509 -text -noout | head -30
```

Look for:
- `Subject:` — should match the hostname
- `Subject Alternative Name:` — should include the hostname
- `Not Before` and `Not After` — should bracket current time
- `Issuer:` — for self-signed equals Subject; for CA-signed shows the CA

### Checking Cert Expiry

```bash
# Days until expiry
kubectl get secret auth-tls -n auth-service \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -enddate

# Output:
# notAfter=Jun 1 12:00:00 2027 GMT
```

For automated monitoring, parse the date and compare to now. Alert when <14 days remain.

### Renewing a Self-Signed Cert

The Secret is the source of truth. To renew:

```bash
# 1. Generate new cert + key (same command as initial)
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /tmp/auth-tls.key \
  -out /tmp/auth-tls.crt \
  -subj "/CN=auth.local/O=auth-local" \
  -addext "subjectAltName = DNS:auth.local"

# 2. Update the existing Secret (rather than delete+create)
kubectl create secret tls auth-tls \
  --cert=/tmp/auth-tls.crt \
  --key=/tmp/auth-tls.key \
  --namespace=auth-service \
  --dry-run=client -o yaml | \
  kubectl apply -f -

# 3. Cleanup local files
rm /tmp/auth-tls.crt /tmp/auth-tls.key

# 4. NGINX Ingress will auto-reload the new cert.
#    No restart of pods or ingress needed.
```

The `--dry-run=client -o yaml | kubectl apply -f -` trick generates the Secret YAML in memory and applies it idempotently, updating the existing Secret rather than failing because it exists.

### Rotating a Cert in Production

For Let's Encrypt via cert-manager: automatic, no action needed.

For ACM: automatic, no action needed.

For self-signed in prod (don't do this, but): same process as dev — update the Secret, NGINX reloads automatically.

### Deleting and Recreating

If something's wrong with a cert (wrong hostname, expired), nuke and recreate:

```bash
kubectl delete secret auth-tls -n auth-service

# Generate fresh and create again
openssl req -x509 -nodes -days 365 ... -out /tmp/auth-tls.crt -keyout /tmp/auth-tls.key
kubectl create secret tls auth-tls --cert=/tmp/auth-tls.crt --key=/tmp/auth-tls.key -n auth-service
rm /tmp/auth-tls.crt /tmp/auth-tls.key
```

NGINX automatically picks up the new Secret. If it doesn't (rare), restart the ingress controller:

```bash
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
```

---

## Common Issues and Their Causes

### "NET::ERR_CERT_AUTHORITY_INVALID" or "Your connection is not private"

Self-signed cert detected. Either:
- **Expected behavior** in dev — click "Advanced → Proceed"
- **In production** — your cert isn't being served. Check that the Ingress references the correct Secret name and the Secret has real data.

### "NET::ERR_CERT_COMMON_NAME_INVALID"

Cert's hostname doesn't match the URL. Causes:
- Cert generated for one hostname, accessed via another
- Missing SAN extension (browser doesn't fall back to CN)
- Wildcard cert but the wildcard scope doesn't match

Fix: regenerate cert with correct hostname in `-subj` and `-addext "subjectAltName = ..."`.

### "NET::ERR_CERT_DATE_INVALID"

Cert expired or not yet valid. Check `openssl x509 -noout -dates`. Renew the cert.

### Browser ignores cert warning override

Some browsers refuse to allow override for certain errors (e.g., HSTS-protected sites). Try in incognito mode first. If still failing, the cert is fundamentally broken — regenerate.

### NGINX Ingress logs show "TLS Secret not found"

The Secret is missing, in the wrong namespace, or named differently than the Ingress expects.

```bash
# Verify Secret exists where Ingress expects
kubectl get secret <secret-name> -n <ingress-namespace>

# Compare to what Ingress says
kubectl get ingress -n <ingress-namespace> -o yaml | grep -A 3 tls:
```

### Certificate works in curl but not browser

curl uses its own bundled trust store. Browsers use the OS or their own. Some `.local` configurations work for curl but trigger stricter checks in browsers.

Fix: either accept the warning in the browser, or add to the system trust store.

### Cert renewed but browser still shows old cert

Browser cache. Try hard refresh (Cmd+Shift+R) or incognito mode. If still showing old cert, NGINX may not have reloaded — restart the ingress controller.

### "Common Name will be ignored" warning from openssl

Modern openssl warns when you set CN without a SAN, because browsers don't use CN anymore. Not an error — the cert is still valid for serving. But add `-addext "subjectAltName = DNS:..."` to silence the warning and ensure browser acceptance.

---

_Last updated: 2026-06-01. Update when the TLS approach changes (e.g., when migrating from self-signed dev to ACM in EKS)._
