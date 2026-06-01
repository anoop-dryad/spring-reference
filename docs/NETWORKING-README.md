# Networking Reference — Minikube Deployment

> **Purpose**: How traffic flows from your browser to a Spring Boot pod, and how every layer is configured. Use this when something stops working and you've forgotten which knob to turn.

---

## Table of Contents

1. [The Big Picture](#the-big-picture)
2. [Layer-by-Layer Walkthrough](#layer-by-layer-walkthrough)
3. [The Three Network Domains](#the-three-network-domains)
4. [Why minikube tunnel Is Required on Mac](#why-minikube-tunnel-is-required-on-mac)
5. [Inside-Cluster Networking](#inside-cluster-networking)
6. [DNS — How Names Resolve at Each Layer](#dns--how-names-resolve-at-each-layer)
7. [TLS Termination — Where Encryption Starts and Ends](#tls-termination--where-encryption-starts-and-ends)
8. [Ports — What Listens Where](#ports--what-listens-where)
9. [Daily Workflow](#daily-workflow)
10. [Troubleshooting by Symptom](#troubleshooting-by-symptom)
11. [Production Equivalents (AWS EKS)](#production-equivalents-aws-eks)

---

## The Big Picture

```
┌─────────────────────────────────────────────────────────────────────┐
│  YOUR MAC                                                           │
│                                                                     │
│   Browser/curl                                                      │
│        │                                                            │
│        │ https://auth.local                                         │
│        ▼                                                            │
│   /etc/hosts                                                        │
│   "auth.local 127.0.0.1"                                            │
│        │                                                            │
│        │ resolves to 127.0.0.1                                      │
│        ▼                                                            │
│   TCP to 127.0.0.1:443                                              │
│        │                                                            │
│        │ caught by minikube tunnel (running as sudo)                │
│        ▼                                                            │
└────────┼────────────────────────────────────────────────────────────┘
         │
         │ Network bridge into minikube VM
         │
┌────────┼────────────────────────────────────────────────────────────┐
│ MINIKUBE VM (Docker Desktop's Linux VM)                             │
│        │                                                            │
│        ▼                                                            │
│   minikube container at 192.168.49.2                                │
│        │                                                            │
│        │ port 443                                                   │
│        ▼                                                            │
│   ingress-nginx-controller pod                                      │
│   • Reads TLS Secret "auth-tls"                                     │
│   • Terminates TLS (decrypts HTTPS → HTTP)                          │
│   • Reads Host header → "auth.local"                                │
│   • Matches Ingress rule for auth.local                             │
│        │                                                            │
│        │ HTTP plaintext (inside-cluster traffic)                    │
│        ▼                                                            │
│   Service "auth-service" (ClusterIP 10.x.x.x:8081)                  │
│   • Selects pods matching app.kubernetes.io/name=auth-service       │
│   • Load-balances across replicas (currently 1)                     │
│        │                                                            │
│        ▼                                                            │
│   Pod auth-service-xxx (10.244.0.y:8081)                            │
│   • Spring Boot listens on container port 8081                      │
│   • Processes the HTTP request                                      │
│   • Calls Postgres at "postgres" Service DNS                        │
│        │                                                            │
│        │ JDBC connection                                            │
│        ▼                                                            │
│   Service "postgres" (headless, no ClusterIP)                       │
│        │                                                            │
│        ▼                                                            │
│   Pod postgres-0 (10.244.0.z:5432)                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

Every arrow is a network hop. Every box is somewhere a packet has to be processed. Understanding which box is failing is 80% of troubleshooting.

---

## Layer-by-Layer Walkthrough

For each hop, you should know:
- What it does
- How it's configured
- How to verify it
- What breaks here

### Hop 1: Browser → DNS Resolution

**What it does**: Looks up `auth.local` to find an IP address.

**How configured**: Manual entry in `/etc/hosts`:
```
127.0.0.1 auth.local
```

**How to verify**:
```bash
grep auth.local /etc/hosts
# Should show: 127.0.0.1 auth.local

# Confirm DNS resolution
ping -c 1 auth.local
# Should ping 127.0.0.1, not fail with "unknown host"
```

**What breaks**: If `/etc/hosts` doesn't have the entry, browser shows "ERR_NAME_NOT_RESOLVED". Or if it points at the old minikube IP (192.168.49.2) instead of 127.0.0.1, connection times out.

### Hop 2: TCP Connection to 127.0.0.1:443

**What it does**: Browser opens a TCP socket to localhost port 443.

**How configured**: This works because `minikube tunnel` listens on 127.0.0.1:443 and 127.0.0.1:80.

**How to verify**:
```bash
# Should connect (returns immediately, not hang)
nc -zv 127.0.0.1 443

# OR — list what's listening on 443
sudo lsof -i :443
# Should show kubectl or minikube tunnel process
```

**What breaks**: If `sudo minikube tunnel` isn't running, nothing's listening on 443. curl times out after ~80 seconds. Fix: start the tunnel.

### Hop 3: minikube tunnel → Minikube VM

**What it does**: Bridges 127.0.0.1:443 on Mac to port 443 on the minikube container.

**How configured**: The `sudo minikube tunnel` command sets up network routes. It runs as a foreground process and must stay running.

**How to verify**:
```bash
# In the terminal running tunnel, you should see:
# "Tunnel successfully started"
# "Starting tunnel for service auth-service"

# From another terminal:
ps aux | grep "minikube tunnel"
# Should show the running process
```

**What breaks**: 
- Tunnel terminal closed → connection refused
- Tunnel was started before the Ingress existed → tunnel doesn't know about it (restart tunnel)
- Mac sleep can disrupt the tunnel (restart it after wake)

### Hop 4: Minikube Container → NGINX Ingress Controller

**What it does**: The minikube container forwards port 443 to the ingress-nginx-controller pod inside.

**How configured**: When you enabled `minikube addons enable ingress`, minikube installed the NGINX Ingress Controller, which uses hostPort 80/443 on the minikube node.

**How to verify**:
```bash
# Controller pod is healthy
kubectl get pods -n ingress-nginx
# Should show: ingress-nginx-controller-xxx  1/1  Running

# Controller is listening (from inside minikube)
minikube ssh -- "sudo netstat -tlnp | grep -E ':80|:443'"
# Should show nginx listening
```

**What breaks**: Ingress controller pod crashed → 502 Bad Gateway from anything that does reach the minikube container.

### Hop 5: NGINX → Ingress Resource Lookup

**What it does**: NGINX receives the HTTPS request, reads the `Host:` header (`auth.local`), and finds the matching Ingress resource.

**How configured**: Your Ingress resource (`k8s/base/auth-service/ingress.yml`):
```yaml
spec:
  ingressClassName: nginx
  tls:
    - hosts: [auth.local]
      secretName: auth-tls
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

**How to verify**:
```bash
kubectl get ingress -n auth-service
# Should show:
# NAME           CLASS   HOSTS        ADDRESS         PORTS     AGE
# auth-service   nginx   auth.local   192.168.49.2    80, 443   ...

# Verify NGINX loaded it
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20 | grep auth.local
```

**What breaks**: 
- Wrong hostname in Ingress rule → 404
- Wrong service name in backend → 503
- Wrong port → connection refused at Service layer

### Hop 6: TLS Termination via auth-tls Secret

**What it does**: NGINX uses the cert + key from the `auth-tls` Secret to decrypt the incoming HTTPS.

**How configured**: The Ingress references `secretName: auth-tls`. The Secret was created manually:
```bash
kubectl create secret tls auth-tls \
  --cert=/tmp/auth-tls.crt \
  --key=/tmp/auth-tls.key \
  --namespace=auth-service
```

**How to verify**:
```bash
kubectl get secret auth-tls -n auth-service
# TYPE should be: kubernetes.io/tls
# DATA should be: 2

# Peek at cert (verify it's for auth.local)
kubectl get secret auth-tls -n auth-service -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -text -noout | grep -A 1 "Subject:"
```

**What breaks**:
- Secret doesn't exist → NGINX uses a self-generated fallback cert (browser warning gets worse)
- Cert hostname doesn't match URL → browser refuses to proceed even after "Advanced"
- Cert expired → same

### Hop 7: NGINX → Service auth-service

**What it does**: NGINX forwards the decrypted HTTP request to the auth-service Service.

**How configured**: The Service resource (`k8s/base/auth-service/service.yml`):
```yaml
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8081
      targetPort: http   # named port from Deployment
  selector:
    app.kubernetes.io/name: auth-service
```

**How to verify**:
```bash
kubectl get service auth-service -n auth-service
# Should show a CLUSTER-IP and port 8081

# Verify it has endpoints (pods matched by selector)
kubectl get endpoints auth-service -n auth-service
# Should show endpoint IPs

# Verify pods match the selector
kubectl get pods -n auth-service -l app.kubernetes.io/name=auth-service
```

**What breaks**:
- Service has no endpoints → no pods match its selector → 503 from ingress
- Pod isn't Ready → endpoint removed from Service → traffic skips it

### Hop 8: Service → Pod

**What it does**: Kubernetes' kube-proxy load-balances across all healthy endpoints of the Service.

**How configured**: Automatic. As long as pods have correct labels AND pass their readiness probe, they're in the endpoint pool.

**How to verify**:
```bash
# Pod labels match service selector
kubectl get pod -n auth-service -l app.kubernetes.io/name=auth-service \
  -o jsonpath='{.items[*].metadata.labels}'

# Pod is Ready (passing readiness probe)
kubectl get pods -n auth-service
# READY column should show 1/1
```

**What breaks**:
- Pod fails readiness → removed from endpoint pool → traffic still works if other pods exist, otherwise 503
- Pod labels don't match → never in pool

### Hop 9: Pod → Spring Boot on Port 8081

**What it does**: Spring Boot processes the HTTP request and returns a response.

**How configured**: 
- `server.port: 8081` in application.yaml (mounted from ConfigMap)
- Deployment exposes containerPort 8081 with name `http`

**How to verify**:
```bash
# Spring Boot is bound to the port
kubectl exec -n auth-service -l app.kubernetes.io/name=auth-service -- \
  netstat -tlnp 2>/dev/null | grep 8081 || \
  kubectl exec -n auth-service $(kubectl get pod -n auth-service -l app.kubernetes.io/name=auth-service -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'wget -O- http://localhost:8081/actuator/health 2>/dev/null'

# Tail logs to see Spring Boot processing requests
kubectl logs -n auth-service -l app.kubernetes.io/name=auth-service --tail=20
```

**What breaks**:
- Spring Boot crash during startup → pod CrashLoopBackOff
- Spring Boot listening on wrong port → readiness probe fails → pod never Ready

### Hop 10: Pod → Postgres (Inside-Cluster Call)

**What it does**: Spring Boot's JDBC driver connects to Postgres via the `postgres` Service DNS name.

**How configured**:
- application.yaml: `url: "jdbc:postgresql://${PGHOST}:${PGPORT}/${DB_NAME}"`
- Env var: `PGHOST=postgres`, `PGPORT=5432` (from postgres-credentials Secret)
- DNS: `postgres` → Service `postgres.auth-service.svc.cluster.local` → Pod `postgres-0`

**How to verify**:
```bash
# DNS resolves inside auth-service pod
kubectl exec -n auth-service -l app.kubernetes.io/name=auth-service -- \
  nslookup postgres 2>/dev/null || true

# Postgres pod is reachable
kubectl exec -n auth-service $(kubectl get pod -n auth-service -l app.kubernetes.io/name=auth-service -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c 'nc -zv postgres 5432' 2>&1 || true
```

**What breaks**:
- Postgres pod not running → DNS resolves but connection refused
- Wrong PGHOST in app config → connection goes somewhere unexpected
- Wrong DB credentials → connection succeeds, auth fails

---

## The Three Network Domains

It helps to think of three completely independent network domains in this setup:

```
┌─────────────────────────────┐
│ Domain 1: Mac (Your Laptop) │
│                             │
│  IPs: 127.0.0.1, your LAN   │
│  Resolver: /etc/hosts + DNS │
│  Routes via: macOS routing  │
└─────────────────────────────┘
         │
         │ Bridge: sudo minikube tunnel
         ▼
┌─────────────────────────────┐
│ Domain 2: Minikube VM       │
│                             │
│  IP: 192.168.49.2           │
│  This is a Docker container │
│  running on Docker Desktop  │
└─────────────────────────────┘
         │
         │ Bridge: kubelet + kube-proxy
         ▼
┌─────────────────────────────┐
│ Domain 3: Cluster Network   │
│                             │
│  Pod IPs: 10.244.0.0/16     │
│  Service IPs: 10.96.0.0/12  │
│  DNS: CoreDNS               │
└─────────────────────────────┘
```

**Key insight**: each domain has its own IP space. A pod IP like `10.244.0.7` is meaningless on your Mac. The Service IP `10.96.x.x` is meaningless on your Mac. Even `192.168.49.2` (minikube's IP) isn't directly reachable from Mac without `minikube tunnel`.

The only IP your Mac can reliably talk to is `127.0.0.1`, which is why we point `auth.local` there.

---

## Why minikube tunnel Is Required on Mac

On Linux with the Docker driver, the host can reach Docker bridge networks directly. So `192.168.49.2` is reachable from your Linux host, and `/etc/hosts` could point there.

On macOS, Docker Desktop runs containers inside a Linux VM (because macOS can't run Linux containers natively). The VM has its own network. Your Mac can talk to Docker Desktop, but not directly to containers inside the VM.

```
Linux host                              macOS host
──────────                              ──────────

curl 192.168.49.2 ──→ container         curl 192.168.49.2 ──→ ???
(works directly)                        (no route — packets dropped)
```

`minikube tunnel`:
- Detects services with type `LoadBalancer` or `Ingress`
- Creates a route on your Mac that says "traffic to 127.0.0.1 ports 80/443 goes into the minikube VM"
- Bridges the Mac ↔ VM gap

That's why:
- `/etc/hosts` points at `127.0.0.1`, not `192.168.49.2`
- The tunnel must be running for external access
- It needs `sudo` because modifying network routes is a privileged operation

### Alternative: Skip the Tunnel, Use Port-Forward

For day-to-day iteration, port-forward is faster:

```bash
kubectl port-forward -n auth-service svc/auth-service 8081:8081
```

Now `curl http://localhost:8081/actuator/health` works. But:
- You bypass Ingress entirely
- You skip TLS (no HTTPS)
- You hit the Service directly (skipping NGINX routing rules)

Use port-forward for quick checks. Use minikube tunnel + Ingress for "test the full path" verification.

---

## Inside-Cluster Networking

Once traffic is inside the cluster, three things make networking work:

### CoreDNS — Service Discovery

CoreDNS is a pod running in `kube-system` that handles DNS for everything inside the cluster.

```bash
# CoreDNS is running
kubectl get pods -n kube-system | grep coredns
```

It implements the cluster DNS convention:

```
<service>.<namespace>.svc.cluster.local
```

So from any pod in the cluster:
- `postgres` → resolves only within auth-service namespace (short form)
- `postgres.auth-service.svc.cluster.local` → resolves from any namespace (long form)
- `auth-service.auth-service.svc.cluster.local` → the auth-service Service

Test from inside a pod:
```bash
kubectl exec -n auth-service postgres-0 -- nslookup auth-service
# Should resolve to a 10.96.x.x ClusterIP
```

### kube-proxy — Service Routing

`kube-proxy` runs on every node and implements Services in the kernel via iptables (or eBPF on newer setups). When a pod connects to a Service ClusterIP, kube-proxy intercepts the packet and routes it to one of the backend pods.

You never configure kube-proxy directly — it watches the API server and updates rules automatically.

```bash
# kube-proxy is healthy
kubectl get pods -n kube-system | grep kube-proxy
```

### Pod Network — CNI

The Container Network Interface (CNI) plugin gives each pod its own IP. Minikube uses `bridge` CNI by default. Each pod gets an IP from `10.244.0.0/16` (the default pod CIDR).

Pods can talk to each other directly by IP. But pod IPs are ephemeral (change on restart), so you almost always use Services instead.

### Services Are Stable Front-Ends for Ephemeral Pods

```
Pod auth-service-abc123 (10.244.0.5)  ─┐
Pod auth-service-def456 (10.244.0.8)  ─┼── Service auth-service (10.96.x.x)
Pod auth-service-ghi789 (10.244.0.12) ─┘

Pods come and go (replicas scale, rolling updates).
Service IP stays stable for the lifetime of the Service.
Always use Service names, not pod IPs.
```

---

## DNS — How Names Resolve at Each Layer

DNS resolution looks different depending on **where** the lookup happens:

### From Your Mac (Browser/curl)

```
auth.local
    │
    ▼
/etc/hosts file
    │
    ▼
127.0.0.1
```

macOS's resolver checks `/etc/hosts` before going to DNS servers. Our entry short-circuits the lookup.

### From a Pod (Spring Boot → Postgres)

```
postgres
    │
    ▼
CoreDNS in cluster
    │
    │ Cluster DNS convention:
    │   postgres → postgres.auth-service.svc.cluster.local
    ▼
Service ClusterIP (10.96.x.x for ClusterIP)
   OR
Pod IP (10.244.x.x for headless Service)
    │
    ▼
kube-proxy iptables rules route to actual pod
```

The Spring Boot app config has `PGHOST=postgres` (short name). Inside the auth-service namespace, CoreDNS resolves this to the postgres Service.

### From Minikube to External Internet

```
ecr.aws.amazon.com
    │
    ▼
Kubelet's DNS config
    │
    ▼
Upstream DNS (whatever Docker Desktop provides, usually 8.8.8.8 or your router)
    │
    ▼
Real DNS resolution
```

This is how image pulls work — minikube has internet access via Docker Desktop's network.

---

## TLS Termination — Where Encryption Starts and Ends

```
Browser ──HTTPS (encrypted)──→ NGINX Ingress ──HTTP (plaintext)──→ Pod
```

TLS terminates at NGINX. Everything inside the cluster is plaintext HTTP. This is the standard pattern:

**Pros**:
- Pods don't need TLS certs
- CPU overhead of TLS is paid once at the edge
- Easy to inspect traffic between pods for debugging

**Cons**:
- Traffic between pods is plaintext (mitigated by network policies or service mesh)
- Risk if an attacker is already inside the cluster

For most setups (including production EKS), TLS-at-the-edge is fine. For high-security environments, you add a service mesh like Istio for mutual TLS between pods.

### Why You See "Not Secure" Warnings

Self-signed cert → browser doesn't trust it.

Three ways to fix:
1. **Accept and remember** (what you're doing) — click "Advanced" → "Proceed"
2. **Add cert to system trust store** — annoying but eliminates warning
3. **Use real cert via cert-manager + Let's Encrypt** — works if auth.local were a real domain; doesn't work for `.local`

For dev with `.local`, #1 is the practical answer.

---

## Ports — What Listens Where

| Port | Where | What | Listens on |
|---|---|---|---|
| 443 | Your Mac | minikube tunnel | 127.0.0.1 |
| 80 | Your Mac | minikube tunnel (HTTP→HTTPS redirect) | 127.0.0.1 |
| 443 | Minikube VM | NGINX Ingress controller | 192.168.49.2 |
| 80 | Minikube VM | NGINX Ingress controller | 192.168.49.2 |
| 8081 | Pod (auth-service) | Spring Boot | 0.0.0.0 inside pod |
| 5432 | Pod (postgres) | PostgreSQL | 0.0.0.0 inside pod |
| 8081 | Service | auth-service Service | ClusterIP |
| 5432 | Service | postgres Service | None (headless) |

### Why postgres Service Has No ClusterIP

It's a `headless` Service (`clusterIP: None`). For StatefulSets, headless Services are the convention because:
- Each pod gets a stable DNS name (`postgres-0.postgres.auth-service.svc.cluster.local`)
- No load balancing needed for a single Postgres pod
- DNS query returns the pod IPs directly

For a Deployment with multiple replicas (like auth-service), a ClusterIP Service makes more sense because you want load balancing.

---

## Daily Workflow

### Starting the Day

```bash
# 1. Start minikube
minikube start

# 2. Verify cluster is healthy
kubectl get pods -A | grep -v Running
# Should be empty (all pods Running)

# 3. Start tunnel (in separate terminal)
sudo minikube tunnel
# Enter password, leave running

# 4. Verify auth.local works
curl -k https://auth.local/actuator/health
```

### During the Day

Iteration loop for code changes:

```bash
# 1. Make code change
# 2. Commit and push → CI builds new image → CD pushes to ECR

# 3. Force minikube to pull new image
kubectl rollout restart deployment/auth-service -n auth-service

# 4. Watch the rollout
kubectl rollout status deployment/auth-service -n auth-service

# 5. Test
curl -k https://auth.local/actuator/health
```

For manifest-only changes:

```bash
# 1. Edit YAML
# 2. Apply
kubectl apply -k k8s/overlays/dev/auth-service

# 3. Restart if needed (e.g., ConfigMap changed)
kubectl rollout restart deployment/auth-service -n auth-service
```

### Ending the Day

```bash
# 1. Ctrl+C the tunnel terminal

# 2. Stop minikube (preserves state)
minikube stop
```

Next morning, `minikube start` resumes everything.

---

## Troubleshooting by Symptom

### `curl: Failed to connect to auth.local port 443`

Connection isn't even completing. Check in order:

```bash
# 1. /etc/hosts entry exists?
grep auth.local /etc/hosts

# 2. Tunnel running?
ps aux | grep "minikube tunnel"

# 3. Something listening on 443?
sudo lsof -i :443
```

Most common: tunnel terminated. Restart it.

### Browser shows "ERR_CONNECTION_REFUSED"

Same as above. Tunnel isn't running or /etc/hosts is wrong.

### Browser shows cert warning forever, can't proceed

Cert has the wrong hostname. Check:

```bash
kubectl get secret auth-tls -n auth-service -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -text -noout | grep -A 1 "Subject:"
```

Subject CN should be `auth.local` AND SubjectAltName should include `DNS:auth.local`.

### Curl works but browser doesn't (or vice versa)

Browsers cache aggressively, especially for TLS errors. Try:
- Incognito/private window
- Different browser
- Hard refresh (Cmd+Shift+R)

### `kubectl get ingress` shows empty ADDRESS

Ingress controller hasn't claimed it yet. Check:

```bash
kubectl get pods -n ingress-nginx
# Controller pod must be Running

kubectl describe ingress auth-service -n auth-service
# Look at Events at the bottom
```

If controller is missing entirely:
```bash
minikube addons enable ingress
```

### 503 Service Unavailable

Ingress is working but can't find healthy backends.

```bash
# Service has endpoints?
kubectl get endpoints auth-service -n auth-service
# Should show pod IPs

# Pods are Ready?
kubectl get pods -n auth-service
# READY column 1/1, not 0/1
```

Most common: pod startup failure. Check `kubectl logs <pod> --previous`.

### Pod is Running but readiness probe failing

```bash
# What does the probe see?
kubectl describe pod <pod-name> -n auth-service | grep -A 5 "Events"

# Look at the actual endpoint
kubectl exec -n auth-service <pod-name> -- \
  wget -O- http://localhost:8081/actuator/health/readiness 2>&1
```

### auth-service pod can't reach postgres

```bash
# DNS works?
kubectl exec -n auth-service <auth-pod> -- nslookup postgres

# TCP works?
kubectl exec -n auth-service <auth-pod> -- nc -zv postgres 5432

# Credentials right?
kubectl exec -n auth-service <auth-pod> -- env | grep -E "PGHOST|DB_"
```

---

## Production Equivalents (AWS EKS)

When you move to real EKS, these layers stay conceptually the same but use different implementations:

| Layer | Minikube | AWS EKS |
|---|---|---|
| DNS for users | /etc/hosts | Route 53 |
| External access | minikube tunnel | Application Load Balancer (ALB) |
| TLS cert | Self-signed via openssl | ACM (AWS Certificate Manager) |
| Ingress controller | NGINX Ingress | AWS Load Balancer Controller (creates ALB) |
| TLS secret | kubectl create secret tls | ALB references ACM cert ARN directly |
| Image pull | ECR Public (no auth) | ECR Private (node IAM role) |
| Storage | Hostpath provisioner | EBS via CSI driver |
| Pod network | Bridge CNI | AWS VPC CNI (pods get VPC IPs) |
| Service mesh (optional) | None | App Mesh, Istio, or Linkerd |

The Deployment, Service, ConfigMap, Secret, and HPA manifests are **identical** between dev and prod. Only the Ingress annotations and the storage class differ.

### Sample EKS Ingress (for reference)

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:...:certificate/...
spec:
  ingressClassName: alb
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

Compare with dev:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [auth.local]
      secretName: auth-tls
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

Annotations differ. `ingressClassName` differs. TLS configuration differs (Secret vs. ACM ARN). The rules structure is identical.

---

_Last updated: 2026-06-01. Update when networking topology or critical configs change._
