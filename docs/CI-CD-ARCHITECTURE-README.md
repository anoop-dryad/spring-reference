# CI/CD Architecture Reference

## Spring Boot · ECR Public · Minikube · Kustomize → EKS

> **Purpose**: Complete reference for this pipeline. Decision log, onboarding guide, AWS migration checklist, and operational runbook.
>
> **Audience**: You — six months from now, when you've forgotten why something was set up a certain way.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [System Architecture](#system-architecture)
3. [Repository Structure](#repository-structure)
4. [The Three Independent Worlds](#the-three-independent-worlds)
5. [CI Pipeline — PR Check](#ci-pipeline--pr-check)
6. [CD Pipeline — Build, Push, Deploy](#cd-pipeline--build-push-deploy)
7. [Docker — Multi-stage Build & Layer Caching](#docker--multi-stage-build--layer-caching)
8. [Kustomize — Overlay Strategy](#kustomize--overlay-strategy)
9. [Kubernetes Manifest Inventory](#kubernetes-manifest-inventory)
10. [Data Flow Diagrams](#data-flow-diagrams)
11. [Environment Promotion Model](#environment-promotion-model)
12. [Secrets Management](#secrets-management)
13. [Dependency & Security Strategy](#dependency--security-strategy)
14. [Spring Boot — Production Checklist](#spring-boot--production-checklist)
15. [Minikube — Local Setup & Deployment](#minikube--local-setup--deployment)
16. [GitHub Environments & Approval Gates](#github-environments--approval-gates)
17. [Adding a New Microservice](#adding-a-new-microservice)
18. [AWS Migration Guide (Minikube → EKS)](#aws-migration-guide-minikube--eks)
19. [Observability — What to Add Next](#observability--what-to-add-next)
20. [Operational Runbook](#operational-runbook)
21. [Decision Log](#decision-log)

---

## Executive Summary

This is a multi-service Spring Boot monorepo with a layered CI/CD pipeline targeting Kubernetes. The reference service is `auth-service` — JWT-based authentication, Spring Boot 4, PostgreSQL 16, Flyway migrations.

**Pipeline stages:**

```
Developer        GitHub Actions             Image Registry      Cluster
─────────        ──────────────             ──────────────      ───────
Push PR    →    CI: test + CodeQL
                (~5 min, no Docker)

Merge main →    CD Phase 1: build image  →  ECR Public
                CD Phase 2: kubectl apply ────────────────────→  AWS EKS dev
                                                                  (when configured)

You manually →                              ECR Public        →  Minikube (local)
                                                                  (kubectl apply)
```

**Design principles:**

- **CI is fast** — no image builds on PRs (~5 minutes target)
- **Security scans split by cadence** — fast checks on PRs, heavy scans nightly
- **Image registry is shared** — both minikube (manual) and EKS (CD-driven) pull from ECR Public
- **Kustomize for env diffs** — one base, overlays for dev/staging/prod
- **Manual minikube deployment** — GitHub Actions can't reach your laptop; that's by design
- **Auto-rollback on failed rollouts** — CD reverts to last good ReplicaSet automatically
- **EKS migration is straightforward** — manifests are 90% reusable; only env-specific overlays change

---

## System Architecture

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              GitHub Repository                                │
│                                                                              │
│   .github/workflows/                  services/auth-service/                 │
│   ├── ci-auth-service.yml             ├── pom.xml                            │
│   ├── cd-auth-service.yml             ├── Dockerfile                         │
│   ├── reusable-java-pr-check.yml      └── src/                               │
│   └── reusable-java-cd.yml                                                   │
│                                       k8s/                                   │
│   .github/dependabot.yml              ├── base/auth-service/                 │
│                                       └── overlays/{dev,staging,prod}/       │
│                                                  auth-service/               │
└─────────────────────┬────────────────────────────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        │ Pull request               │ Merge to main
        ▼                            ▼
┌────────────────┐         ┌──────────────────┐
│   CI Workflow  │         │   CD Workflow    │
│   (PR check)   │         │   Phase 1: Build │
│                │         │   Phase 2: Deploy│
│  • Maven test  │         └────────┬─────────┘
│  • CodeQL      │                  │
│  • Coverage    │                  ▼
└────────────────┘         ┌──────────────────┐
                           │ ECR Public       │
                           │ auth-service:tag │
                           └────────┬─────────┘
                                    │
                ┌───────────────────┴─────────────────────┐
                │                                         │
                ▼ (manual kubectl apply)                  ▼ (CD-driven)
        ┌───────────────┐                        ┌────────────────────┐
        │   Minikube    │                        │   AWS EKS clusters │
        │   (your Mac)  │                        │   dev/staging/prod │
        │               │                        │                    │
        │ • For learning│                        │ • Real deployment  │
        │ • Manual ops  │                        │ • Automated by CD  │
        └───────────────┘                        └────────────────────┘
```

### Production-Ready Workflow Files

| File                                            | Trigger                            | Purpose                                 |
| ----------------------------------------------- | ---------------------------------- | --------------------------------------- |
| `.github/workflows/ci-auth-service.yml`         | PR to main                         | Calls reusable PR-check workflow        |
| `.github/workflows/cd-auth-service.yml`         | Merge to main, `workflow_dispatch` | Builds image, deploys to env            |
| `.github/workflows/reusable-java-pr-check.yml`  | `workflow_call` from CI            | Build, test, CodeQL                     |
| `.github/workflows/reusable-java-cd.yml`        | `workflow_call` from CD            | Build image, push to ECR, kubectl apply |
| `.github/workflows/scheduled-security-scan.yml` | Nightly cron + manual              | OWASP, full Semgrep                     |
| `.github/dependabot.yml`                        | Continuous (GitHub-managed)        | Dependency CVE alerts + version updates |

---

## Repository Structure

```
spring-reference/
│
├── .github/
│   ├── dependabot.yml                          # Continuous dep CVE surveillance
│   └── workflows/
│       ├── reusable-java-pr-check.yml          # CI: shared, called by ci-*.yml
│       ├── reusable-java-cd.yml                # CD: shared, called by cd-*.yml
│       ├── scheduled-security-scan.yml         # Nightly OWASP + full Semgrep
│       ├── ci-auth-service.yml                 # Per-service CI caller
│       └── cd-auth-service.yml                 # Per-service CD caller
│
├── auth-service/                               # Spring Boot service
│   ├── pom.xml                                 # Maven deps, version overrides
│   ├── Dockerfile                              # Multi-stage build
│   ├── Makefile                                # Dev convenience commands
│   ├── .envrc.example                          # Local dev env template
│   ├── setup_db.sh                             # Postgres bootstrap script
│   └── src/
│       ├── main/
│       │   ├── java/.../auth/                  # Java source
│       │   └── resources/
│       │       ├── application.yml             # Defaults
│       │       └── db/migration/               # Flyway migrations
│       │           ├── V1__create_users_table.sql
│       │           └── V2__...sql
│       └── test/
│
├── k8s/                                        # Kubernetes manifests
│   ├── base/
│   │   └── auth-service/                       # Env-agnostic resources
│   │       ├── kustomization.yaml              # Lists all base resources
│   │       ├── namespace.yaml
│   │       ├── configmap.yaml                  # Non-secret config
│   │       ├── secrets.yaml                    # Placeholder secrets
│   │       ├── postgres-statefulset.yaml       # Postgres pod + PVC template
│   │       ├── postgres-service.yaml           # Postgres internal DNS
│   │       ├── deployment.yaml                 # auth-service pods
│   │       ├── service.yaml                    # auth-service internal DNS
│   │       ├── ingress.yaml                    # External HTTPS routing
│   │       └── hpa.yaml                        # Horizontal Pod Autoscaler
│   │
│   └── overlays/
│       ├── dev/auth-service/                   # Minikube-specific
│       │   ├── kustomization.yaml              # Imports base + patches
│       │   ├── secrets.yaml                    # REAL values (GITIGNORED)
│       │   ├── patch-deployment.yaml           # Smaller resources, pull policy
│       │   ├── patch-hpa.yaml                  # min=max=1
│       │   └── patch-ingress.yaml              # auth.local hostname
│       │
│       ├── staging/auth-service/               # AWS EKS staging
│       │   └── (TBD when EKS is set up)
│       │
│       └── prod/auth-service/                  # AWS EKS prod
│           └── (TBD; add PodDisruptionBudget)
│
└── docs/
    ├── CI-CD-ARCHITECTURE.md                   # This file
    ├── DATABASE_SETUP.md                       # Postgres bootstrap
    └── README.md                               # Service-level README
```

### .gitignore Essentials

```bash
# Real secret values — never commit
k8s/overlays/*/auth-service/secrets.yaml

# Local env files
.envrc
.env
auth-service/.envrc
auth-service/.env

# Build output
**/target/
**/*.class

# IDE
.idea/
.vscode/

# AWS / kubectl local config
.aws/
.kube/
```

---

## The Three Independent Worlds

This is **the single most important mental model** for understanding this setup. The pipeline exists in three independent worlds that don't directly talk to each other.

```
┌────────────────────────────────────────────────────────────────┐
│ WORLD 1: GitHub Actions (lives in GitHub's cloud)              │
│                                                                │
│ • CI workflow runs on every PR                                 │
│ • CD workflow runs on merge to main                            │
│ • Has no ability to reach your laptop                          │
│ • Talks to ECR (for image push) and EKS (for kubectl apply)    │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ WORLD 2: Image Registry (ECR Public, lives on AWS)             │
│                                                                │
│ • CI/CD pushes images here                                     │
│ • Both Minikube AND EKS pull from here                         │
│ • The bridge between the other two worlds                      │
│ • Currently: public.ecr.aws/o6c1v8x2/auth-service              │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ WORLD 3a: Minikube (lives on your Mac)                         │
│                                                                │
│ • Local Kubernetes for learning and experimentation            │
│ • You deploy here MANUALLY via kubectl apply                   │
│ • GitHub Actions cannot reach this                             │
│ • Pulls images from ECR Public (no auth needed)                │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ WORLD 3b: AWS EKS (lives on AWS, when configured)              │
│                                                                │
│ • Real environments: dev / staging / prod                      │
│ • Deployed by CD pipeline via kubectl apply                    │
│ • Uses kubeconfig stored in GitHub Secrets                     │
│ • Pulls images from ECR Public (or ECR Private later)          │
└────────────────────────────────────────────────────────────────┘
```

### What This Means in Practice

| Scenario              | Who initiates           | What happens                                           |
| --------------------- | ----------------------- | ------------------------------------------------------ |
| Open PR               | You (push)              | CI runs in GitHub. Tests pass/fail. Nothing deployed.  |
| Merge to main         | You (merge button)      | CD builds image, pushes to ECR, deploys to dev EKS     |
| Deploy to staging     | You (workflow_dispatch) | CD picks an existing image tag, deploys to staging EKS |
| Deploy to prod        | You (workflow_dispatch) | CD waits for approval, then deploys to prod EKS        |
| Local minikube deploy | You (kubectl apply)     | You manually apply manifests to your local minikube    |

**The CD pipeline does NOT deploy to minikube.** There's no network path from GitHub Actions to your laptop. Minikube is a sandbox you control directly.

---

## CI Pipeline — PR Check

**File**: `.github/workflows/reusable-java-pr-check.yml`
**Caller**: `.github/workflows/ci-auth-service.yml`
**Triggered by**: Pull requests targeting `main` (filtered by `paths: ["auth-service/**"]`)
**Duration target**: ~5 minutes

### What Runs on Every PR

```
┌─────────────────────────────────────┐
│ Job A: build-test                   │ ─┐
│ • Checkout                          │  │
│ • Setup JDK 21 + Maven cache        │  │ Run in parallel
│ • Start Postgres service container  │  │
│ • mvn verify (tests + coverage)     │  │
│ • Upload JaCoCo report              │  │
│ • Publish test results as PR check  │  │
└─────────────────────────────────────┘  │
                                         │
┌─────────────────────────────────────┐  │
│ Job B: codeql                       │ ─┘
│ • Checkout (full history)           │
│ • Setup JDK 21                      │
│ • CodeQL init (manual build-mode)   │
│ • Compile (mvn package)             │
│ • CodeQL analyze + upload SARIF     │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Job C: pr-check (aggregator)        │
│ • Runs after A and B finish         │
│ • Reports overall pass/fail         │
│ • Branch protection requires THIS   │
└─────────────────────────────────────┘
```

### What Does NOT Run on PRs

Deliberate decisions to keep PR checks fast:

- ❌ **No Docker image build** — saves ~2 minutes per PR
- ❌ **No OWASP Dependency-Check** — moved to nightly schedule
- ❌ **No full Semgrep scan** — moved to nightly schedule

The reasoning: per-PR scans that don't gate the build add cost without preventing anything. Heavy security scans run nightly against `main`, where findings produce actionable alerts.

### Postgres Service Container

```yaml
services:
  postgres:
    image: postgres:16-alpine
    env:
      POSTGRES_DB: testdb
      POSTGRES_USER: testuser
      POSTGRES_PASSWORD: testpass
    options: >-
      --health-cmd pg_isready
      --health-interval 5s
```

GitHub Actions service containers are auto-healthchecked and torn down at job end. Cleaner than running `docker run` manually.

### Concurrency Control

```yaml
concurrency:
  group: pr-check-${{ inputs.service-name }}-${{ github.ref }}
  cancel-in-progress: true
```

When a developer pushes multiple commits in succession, only the latest CI run completes. Older runs are cancelled. Saves Actions minutes.

---

## CD Pipeline — Build, Push, Deploy

**File**: `.github/workflows/reusable-java-cd.yml`
**Caller**: `.github/workflows/cd-auth-service.yml`
**Triggered by**:

- Auto: merge to `main` (filtered by paths) → deploys to **dev**
- Manual: `workflow_dispatch` → deploys to **staging** or **prod**

### Two Phases

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 1: Build & Push                                   │
│                                                         │
│  Checkout code                                          │
│      ↓                                                  │
│  Setup JDK 21 + Maven cache                             │
│      ↓                                                  │
│  mvn package -DskipTests                                │
│  (tests already passed in CI; rebuilding is enough)     │
│      ↓                                                  │
│  Setup docker buildx (multi-arch)                       │
│      ↓                                                  │
│  Authenticate to ECR Public                             │
│  (GitHub Actions OIDC → AWS IAM role)                   │
│      ↓                                                  │
│  docker buildx build --platform linux/amd64,linux/arm64 │
│      ↓                                                  │
│  docker push to public.ecr.aws/o6c1v8x2/auth-service    │
│      ↓                                                  │
│  Trivy scan on pushed image                             │
│  (SARIF → GitHub Security tab)                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ PHASE 2: Deploy                                         │
│                                                         │
│  Set up kubeconfig from secret                          │
│  (echo $KUBECONFIG_DEV | base64 -d > ~/.kube/config)    │
│      ↓                                                  │
│  cd k8s/overlays/$ENVIRONMENT/auth-service              │
│      ↓                                                  │
│  kustomize edit set image \                             │
│    auth-service=...:$ENVIRONMENT-${{ github.sha }}      │
│      ↓                                                  │
│  kustomize build | kubectl diff -f -                    │
│  (preview changes in logs for audit trail)              │
│      ↓                                                  │
│  kustomize build | kubectl apply -f -                   │
│      ↓                                                  │
│  kubectl rollout status deployment/auth-service \       │
│    --timeout=5m                                         │
│      ↓                                                  │
│  Smoke test: curl /actuator/health                      │
│      ↓                                                  │
│  Notify Slack on result (optional)                      │
└─────────────────────────────────────────────────────────┘

If rollout fails:
  kubectl rollout undo deployment/auth-service
  Notify: deploy failed, auto-rolled back
```

### Image Tagging Strategy

| Tag format                 | When applied                 | Example                        | Mutable?          |
| -------------------------- | ---------------------------- | ------------------------------ | ----------------- |
| `<git-sha>`                | Every build                  | `auth-service:abc1234`         | No — immutable    |
| `dev-<git-sha>`            | Auto on main merge           | `auth-service:dev-abc1234`     | No — immutable    |
| `staging-<git-sha>`        | Manual staging promote       | `auth-service:staging-abc1234` | No — immutable    |
| `prod-<git-sha>`           | Manual prod promote (gated)  | `auth-service:prod-abc1234`    | No — immutable    |
| `latest`                   | Latest successful main build | `auth-service:latest`          | **Yes — mutable** |
| `dev` / `staging` / `prod` | Latest deployed per env      | `auth-service:dev`             | **Yes — mutable** |

**Promotion rule**: always promote by immutable SHA tag, never floating tags like `latest`. This guarantees prod runs byte-identical to what was tested in staging.

### Multi-Architecture Builds

Images are built for both `linux/amd64` and `linux/arm64`. Reasons:

- **Apple Silicon dev**: pulling `:arm64` to your M-series Mac avoids QEMU emulation
- **AWS Graviton**: arm64 EC2/EKS instances are ~20% cheaper for equivalent workloads
- **Cost-effective from day one**: switching to Graviton in prod is a single Terraform/eksctl change

### What CD Does NOT Do

- ❌ **Does not create the EKS cluster** — that's a one-time Terraform/eksctl task
- ❌ **Does not create RDS, S3, Secrets Manager resources** — those are infrastructure, separate concern
- ❌ **Does not manage DNS or TLS certs** — Route 53 + ACM are set up once
- ❌ **Does not migrate the database** — Flyway runs on app startup (built into the app)
- ❌ **Does not deploy to minikube** — no network path from GitHub to your laptop

---

## Docker — Multi-stage Build & Layer Caching

```
Dockerfile = 3 stages
─────────────────────
Stage 1 (builder)   maven:3.9-eclipse-temurin-21 → produces fat JAR (~50MB)
Stage 2 (layers)    eclipse-temurin:21-jre-alpine → extracts Spring Boot layers
Stage 3 (runtime)   eclipse-temurin:21-jre-alpine → final image (~180MB)
```

### Spring Boot Layer Extraction

A Spring Boot fat JAR contains:

| Contents                   | Size    | Change frequency              |
| -------------------------- | ------- | ----------------------------- |
| `dependencies/`            | ~45 MB  | Rarely (only on dep upgrades) |
| `spring-boot-loader/`      | ~500 KB | Almost never                  |
| `snapshot-dependencies/`   | ~2 MB   | Occasionally                  |
| `application/` (your code) | ~100 KB | Every commit                  |

Without layer extraction, a code change rebuilds and re-pushes the entire ~50 MB layer. With extraction, only the ~100 KB `application/` layer changes.

**Impact at scale**: 500x smaller pushes, faster rolling deploys, less ECR storage cost.

### Critical JVM Container Flags

```dockerfile
ENV JAVA_OPTS="\
  -XX:+UseContainerSupport \              # Respect cgroup memory limits
  -XX:MaxRAMPercentage=75.0 \             # Heap = 75% of container memory
  -XX:InitialRAMPercentage=50.0 \         # Avoid GC pause from heap resize
  -XX:+UseG1GC \                          # G1 GC, good for Spring Boot
  -XX:+HeapDumpOnOutOfMemoryError \       # Capture heap on OOM
  -XX:HeapDumpPath=/tmp/heapdump.hprof \  # Where to write it
  -XX:+ExitOnOutOfMemoryError \           # Fail fast on OOM (K8s restarts)
  -Djava.security.egd=file:/dev/./urandom" # Faster startup, non-blocking entropy
```

### Why `exec` in ENTRYPOINT Matters

```dockerfile
# ❌ WRONG — sh stays as PID 1, doesn't forward SIGTERM to Java
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]

# ✅ RIGHT — exec replaces sh with Java; Java becomes PID 1
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
```

Without `exec`, Kubernetes' SIGTERM goes to `sh`, which doesn't forward it. The JVM never knows it should shut down, gets SIGKILLed after the 30-second grace period, and you lose:

- In-flight HTTP requests (502s during deploy)
- Clean DB connection pool closure
- Flyway migration completion
- Spring `@PreDestroy` hooks
- Buffered log flushes

With `exec`, the JVM receives SIGTERM directly and shuts down cleanly in ~2 seconds.

### Dependency Override Pattern

Spring Boot's parent POM pins specific versions of tomcat-embed, postgresql driver, etc. To address CVEs faster than Spring Boot releases, override in `pom.xml`:

```xml
<properties>
    <java.version>21</java.version>

    <!-- Force tomcat past 11.0.21 — fixes CVE-2026-43512 et al. -->
    <tomcat.version>11.0.22</tomcat.version>

    <!-- Force postgres driver past 42.7.10 — fixes CVE-2026-42198 -->
    <postgresql.version>42.7.11</postgresql.version>
</properties>
```

**Remove the override** once Spring Boot ships a release pulling in the patched version natively. Dependabot tracks this for you.

---

## Kustomize — Overlay Strategy

### Concept

```
base/auth-service/           ← Manifests shared across all environments
       +
overlays/dev/auth-service/   ← Patches: dev-specific image tag, resources, hostname
       =
Final manifests applied      ← What actually reaches the cluster
```

Kustomize composes the final manifest set by reading the base and applying patches. No string substitution, no templating language — just declarative YAML merging.

### What Lives Where

| Concern                     | Where                                                | Example                                      |
| --------------------------- | ---------------------------------------------------- | -------------------------------------------- |
| Deployment structure        | `base/`                                              | Container spec, probes, volume mounts        |
| Service / Ingress structure | `base/`                                              | Selectors, port definitions                  |
| HPA structure               | `base/`                                              | Target CPU %, scaleDown behavior             |
| Image name (without tag)    | `base/deployment.yaml`                               | `public.ecr.aws/o6c1v8x2/auth-service`       |
| Image tag                   | `overlays/*/kustomization.yaml`                      | Updated by CD via `kustomize edit set image` |
| Replica counts              | `overlays/*/patch-deployment.yaml`                   | dev: 1, prod: 3+                             |
| Resource requests/limits    | `overlays/*/patch-deployment.yaml`                   | dev: 256Mi, prod: 1Gi                        |
| Spring profile, log level   | `overlays/*/kustomization.yaml` (configMapGenerator) | dev: DEBUG, prod: INFO                       |
| Real secret values          | `overlays/*/secrets.yaml` (GITIGNORED)               | Dev passwords, JWT key                       |
| Ingress hostname            | `overlays/*/patch-ingress.yaml`                      | dev: `auth.local`, prod: `auth.example.com`  |
| TLS certificate             | Created in cluster manually                          | Dev: self-signed, prod: ACM via cert-manager |
| PodDisruptionBudget         | `overlays/prod/` only                                | Min 1 available during voluntary disruption  |
| Anti-affinity rules         | `overlays/prod/patch-deployment.yaml`                | Spread pods across nodes/AZs                 |

### Kustomize CLI Operations

```bash
# Preview what will be applied (no changes made)
kubectl kustomize k8s/overlays/dev/auth-service

# Show diff against current cluster state
kubectl diff -k k8s/overlays/dev/auth-service

# Apply
kubectl apply -k k8s/overlays/dev/auth-service

# Standalone kustomize CLI also works
kustomize build k8s/overlays/dev/auth-service | kubectl apply -f -

# Update image tag (used by CD)
cd k8s/overlays/dev/auth-service
kustomize edit set image \
  public.ecr.aws/o6c1v8x2/auth-service=public.ecr.aws/o6c1v8x2/auth-service:dev-abc1234
```

---

## Kubernetes Manifest Inventory

### Base Resources (`k8s/base/auth-service/`)

| File                        | Resource                | Purpose                                                |
| --------------------------- | ----------------------- | ------------------------------------------------------ |
| `namespace.yaml`            | Namespace               | `auth-service` namespace for isolation                 |
| `configmap.yaml`            | ConfigMap               | Non-secret config: ports, DB host, log level, JWT TTLs |
| `secrets.yaml`              | Secret (×2)             | Placeholder secrets; real values come from overlays    |
| `postgres-statefulset.yaml` | StatefulSet             | Postgres pod with persistent PVC                       |
| `postgres-service.yaml`     | Service (headless)      | DNS: `postgres.auth-service.svc.cluster.local`         |
| `deployment.yaml`           | Deployment              | auth-service pods with initContainer + probes          |
| `service.yaml`              | Service (ClusterIP)     | DNS: `auth-service.auth-service.svc.cluster.local`     |
| `ingress.yaml`              | Ingress                 | External HTTPS routing                                 |
| `hpa.yaml`                  | HorizontalPodAutoscaler | CPU/memory-based scaling                               |
| `kustomization.yaml`        | Kustomization           | Orchestrator listing all resources                     |

### Dev Overlay (`k8s/overlays/dev/auth-service/`)

| File                    | Resource         | Purpose                                                   |
| ----------------------- | ---------------- | --------------------------------------------------------- |
| `kustomization.yaml`    | Kustomization    | Imports base + applies dev patches                        |
| `secrets.yaml`          | Secret (×2)      | Real dev passwords (GITIGNORED)                           |
| `patch-deployment.yaml` | Deployment patch | Smaller resources, `imagePullPolicy: IfNotPresent`        |
| `patch-hpa.yaml`        | HPA patch        | `minReplicas: 1, maxReplicas: 1` (no scaling on minikube) |
| `patch-ingress.yaml`    | Ingress patch    | Hostname → `auth.local`, TLS secret → `auth-tls`          |

### Key Manifest Patterns

**InitContainer waits for Postgres** before main container starts:

```yaml
initContainers:
  - name: wait-for-postgres
    image: postgres:16-alpine
    command:
      - sh
      - -c
      - |
        until pg_isready -h postgres -p 5432 -U "$POSTGRES_USER"; do
          echo "Waiting for postgres..."
          sleep 2
        done
```

This prevents Spring Boot from crash-looping on startup when Postgres takes longer to come up than the app.

**Three-probe pattern** for Spring Boot:

| Probe            | When          | Purpose                                           |
| ---------------- | ------------- | ------------------------------------------------- |
| `startupProbe`   | First 150s    | Gives Spring Boot time to start (slow JVM warmup) |
| `livenessProbe`  | After startup | Restarts pod if app deadlocks                     |
| `readinessProbe` | Continuous    | Removes pod from Service LB if not ready          |

```yaml
startupProbe:
  httpGet:
    path: /actuator/health/liveness
    port: http
  failureThreshold: 30 # 30 × 5s = 150s max startup
  periodSeconds: 5

livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: http
  initialDelaySeconds: 60
  periodSeconds: 15

readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: http
  initialDelaySeconds: 20
  periodSeconds: 5
```

---

## Data Flow Diagrams

### End-to-End Request Flow (Inside Cluster)

```
Internet
   │
   │ HTTPS to auth.local
   ▼
┌─────────────────────────────────────────────────┐
│ NGINX Ingress Controller (ingress-nginx ns)     │
│ • Terminates TLS using "auth-tls" Secret        │
│ • Routes by hostname → Service                  │
└─────────────────────┬───────────────────────────┘
                      │ HTTP (plaintext inside cluster)
                      ▼
┌─────────────────────────────────────────────────┐
│ Service "auth-service" (ClusterIP)              │
│ • Load-balances across pod replicas             │
│ • DNS: auth-service.auth-service.svc.cluster... │
└─────────────────────┬───────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        ▼                            ▼
┌──────────────────┐      ┌──────────────────┐
│ Pod auth-service │      │ Pod auth-service │
│  Spring Boot     │      │  Spring Boot     │
│  Port 8081       │      │  Port 8081       │
└────────┬─────────┘      └────────┬─────────┘
         │                         │
         │ JDBC connection         │
         └───────────┬─────────────┘
                     ▼
┌─────────────────────────────────────────────────┐
│ Service "postgres" (headless)                   │
│ • DNS: postgres.auth-service.svc.cluster.local  │
└─────────────────────┬───────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────┐
│ Pod postgres-0 (StatefulSet)                    │
│ • Persistent storage via PVC                    │
│ • PVC: postgres-data-postgres-0                 │
└─────────────────────────────────────────────────┘
```

### CI/CD Image Flow

```
Developer pushes PR
   │
   ▼
CI runs in GitHub Actions
   │
   │ Pass ✓
   ▼
Code merged to main
   │
   ▼
CD Phase 1 (GitHub Actions):
   • mvn package
   • docker buildx build
   • docker push to ECR Public
   │
   ▼
ECR Public has new image
public.ecr.aws/o6c1v8x2/auth-service:dev-<sha>
   │
   ├──────────────────────────────────┐
   │                                  │
   ▼ CD Phase 2 (auto)                ▼ You (manual)
EKS dev cluster:                      Minikube on your Mac:
   kubectl apply -k overlays/dev        kubectl apply -k overlays/dev
   • kubelet pulls from ECR             • kubelet pulls from ECR
   • Rolling update                     • Rolling update
   • New pods serve traffic             • New pods serve traffic
```

### Configuration Injection Flow

```
Source                                Destination
──────                                ───────────

ConfigMap "auth-service-config"
   │ (envFrom)
   ├─ SERVER_PORT=8081
   ├─ DB_HOST=postgres                ┐
   ├─ LOG_LEVEL=INFO                  │
   └─ ...                             │
                                      │
Secret "postgres-credentials"         ├──► Pod environment variables
   │ (envFrom)                        │      │
   ├─ POSTGRES_USER                   │      ▼
   ├─ POSTGRES_PASSWORD               │   Spring Boot reads
   └─ ...                             │   via property resolution:
                                      │   SPRING_DATASOURCE_URL → spring.datasource.url
Secret "auth-service-secrets"         │
   │ (envFrom)                        │
   └─ JWT_SECRET                      ┘

Constructed env vars (in deployment.yaml):
   SPRING_DATASOURCE_URL=jdbc:postgresql://$(DB_HOST):$(DB_PORT)/$(DB_NAME)
```

### Secret Origins by Environment

```
DEV (minikube):
   k8s/overlays/dev/auth-service/secrets.yaml (GITIGNORED, kubectl apply)
                            ↓
                   K8s Secret in cluster
                            ↓
                   Pod environment

STAGING/PROD (EKS):
   AWS Secrets Manager / SSM Parameter Store
                            ↓
                   Secrets Store CSI driver
                            ↓
                   K8s Secret (auto-generated)
                            ↓
                   Pod environment
```

The Deployment manifest doesn't change between dev and prod — only the **source** of the Secret values differs.

---

## Environment Promotion Model

```
feature/* or fix/* branch
       │
       ▼ PR opened
   ┌─────────┐
   │  CI Run │  ← Tests + CodeQL (~5 min)
   └─────────┘
       │ green check + approval
       ▼ merge
   ┌─────────┐
   │   DEV   │  ← auto deploy on merge to main
   │  (EKS)  │     • CD pushes image with tag dev-<sha>
   └─────────┘     • kubectl apply with that tag
       │
       │ workflow_dispatch (manual)
       │ • Pick "staging" + image tag (often the same SHA from dev)
       ▼
   ┌─────────┐
   │ STAGING │  ← Same image, different cluster, different config
   │  (EKS)  │     • Pulls same auth-service:dev-<sha>
   └─────────┘     • Tags it as staging-<sha> (immutable promotion)
       │
       │ workflow_dispatch (manual)
       │ • Pick "prod" + image tag (the one tested in staging)
       │
       ▼ GitHub Environment "prod" gate
       │ → Waits for required reviewer approval
       ▼
   ┌─────────┐
   │  PROD   │  ← Same image, same approval-gated cluster
   │  (EKS)  │     • Pulls same auth-service:dev-<sha> as staging tested
   └─────────┘     • Tags it as prod-<sha>
```

**Promotion principle**: the bytes that ran in dev are the bytes that run in prod. Only the config (env vars, secrets) differs between environments.

**Why this matters**: when staging passes but prod fails, you can rule out "the build differs." Either it's config (env vars), data (production-only edge case), or load (scale-only behavior). The image is identical.

---

## Secrets Management

### GitHub Secrets — Required

| Secret               | Scope                | Purpose                                       | How to generate                                    |
| -------------------- | -------------------- | --------------------------------------------- | -------------------------------------------------- |
| `AWS_ACCOUNT_ID`     | Repo                 | AWS account for ECR                           | From AWS console                                   |
| `AWS_REGION`         | Repo                 | ECR region (e.g., `us-east-1` for ECR Public) | Static                                             |
| `NVD_API_KEY`        | Repo                 | OWASP scan rate limit                         | https://nvd.nist.gov/developers/request-an-api-key |
| `KUBECONFIG_DEV`     | Environment: dev     | base64 kubeconfig for dev EKS                 | See "Generating Kubeconfig"                        |
| `KUBECONFIG_STAGING` | Environment: staging | base64 kubeconfig for staging EKS             | Same                                               |
| `KUBECONFIG_PROD`    | Environment: prod    | base64 kubeconfig for prod EKS                | Same                                               |

### Secrets NOT Needed (Anymore)

| Secret               | Why removed                       |
| -------------------- | --------------------------------- |
| `DOCKERHUB_USERNAME` | Using ECR Public instead          |
| `DOCKERHUB_TOKEN`    | Using ECR Public instead          |
| `SEMGREP_APP_TOKEN`  | Using Semgrep OSS in nightly only |

### Generating Kubeconfig Secret

```bash
# For an existing EKS cluster
aws eks update-kubeconfig --name dev-cluster --region us-east-1

# Encode for GitHub Secret
cat ~/.kube/config | base64 | pbcopy
# Paste into GitHub Settings → Secrets → KUBECONFIG_DEV
```

### Kubernetes Secrets — In-Cluster

**Dev (minikube)**: store real values in gitignored `k8s/overlays/dev/auth-service/secrets.yaml`, applied via `kubectl apply -k`.

**Prod (EKS)**: source from AWS Secrets Manager via Secrets Store CSI driver:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: auth-service-aws-secrets
  namespace: auth-service
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "prod/auth-service/postgres-password"
        objectType: "secretsmanager"
      - objectName: "prod/auth-service/jwt-secret"
        objectType: "secretsmanager"
  secretObjects:
    - secretName: postgres-credentials
      type: Opaque
      data:
        - objectName: "prod/auth-service/postgres-password"
          key: POSTGRES_PASSWORD
    - secretName: auth-service-secrets
      type: Opaque
      data:
        - objectName: "prod/auth-service/jwt-secret"
          key: JWT_SECRET
```

The Deployment references `postgres-credentials` and `auth-service-secrets` the same way in both environments. The CSI driver fills them from AWS for prod; manual kubectl apply fills them for dev.

---

## Dependency & Security Strategy

### Three-Layered Approach

```
Layer 1: CONTINUOUS (Dependabot)
─────────────────────────────────
• CVE in jackson-databind published → alert appears in minutes
• Dependabot opens PR with version bump within hours
• Runs on GitHub's infrastructure, zero Actions minutes
• Catches 95% of dependency vulnerabilities

Layer 2: PER-PR (CI Workflow)
─────────────────────────────
• Build + tests + CodeQL on every PR
• Fast (~5 min), gates merge
• Catches: code-level bugs, common security patterns

Layer 3: NIGHTLY (Scheduled Workflow)
─────────────────────────────────────
• Full OWASP Dependency-Check
• Full Semgrep rule set (java, owasp-top-ten, spring-boot)
• Runs at 03:00 UTC, off the PR critical path
• Catches: dependency CVEs that Dependabot couldn't auto-fix,
  code patterns that the lighter PR scan missed
```

### Why This Layering

Running OWASP and full Semgrep on every PR was the original setup. We moved away from it because:

1. **Scans were non-blocking** (`continue-on-error: true`) — paying the time cost without enforcement
2. **PR feedback got slow** — 15+ min per PR meant devs waited or merged without checking
3. **Same findings repeated** across dozens of PRs without triage
4. **NVD database download** was slow even with caching

The nightly schedule catches the same issues with better cost economics, and findings flow to the GitHub Security tab where they're triaged centrally.

### Dependabot Configuration

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: maven
    directory: "/auth-service"
    schedule:
      interval: weekly
      day: monday
    groups:
      production-minor-patch:
        applies-to: version-updates
        dependency-type: production
        update-types: [minor, patch]

  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly

  - package-ecosystem: docker
    directory: "/auth-service"
    schedule:
      interval: weekly
```

**Why weekly, not daily**: security CVEs come through Dependabot alerts continuously (not the schedule). The schedule only controls non-security version bumps, which don't need 24-hour turnaround.

### Dependency Version Override Pattern

When a CVE is published affecting a dependency Spring Boot manages, override in `pom.xml` rather than waiting for Spring Boot to release:

```xml
<properties>
    <tomcat.version>11.0.22</tomcat.version>      <!-- CVE fix -->
    <postgresql.version>42.7.11</postgresql.version> <!-- CVE fix -->
</properties>
```

**Lifecycle of an override**:

1. CVE published; Dependabot or OWASP scan flags it
2. Add `<x.version>` override pointing at the patched version
3. Verify: `mvn dependency:tree -Dincludes=<group>:<artifact>` shows the new version
4. Verify: `mvn org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=7` passes
5. **Later**: Spring Boot ships a release with the patched version → remove the override

### Useful Maven Commands for Dependency Audit

```bash
# Show what version is actually being resolved
mvn dependency:tree -Dincludes=org.apache.tomcat.embed:tomcat-embed-core

# Show all version properties and what newer versions are available
mvn versions:display-property-updates

# Run OWASP scan locally
mvn org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=7
```

A Makefile in each service exposes these as targets:

```makefile
dep-tomcat:
	mvn dependency:tree -Dincludes=org.apache.tomcat.embed:tomcat-embed-core

dep-postgres:
	mvn dependency:tree -Dincludes=org.postgresql:postgresql

dep-updates:
	mvn versions:display-property-updates

dep-check LIB:
	mvn dependency:tree -Dincludes=$(LIB)
```

---

## Spring Boot — Production Checklist

### Required `application.yml`

```yaml
spring:
  application:
    name: auth-service

  datasource:
    url: ${SPRING_DATASOURCE_URL}
    username: ${SPRING_DATASOURCE_USERNAME}
    password: ${SPRING_DATASOURCE_PASSWORD}
    hikari:
      maximum-pool-size: 10
      minimum-idle: 2
      connection-timeout: 5000

  flyway:
    enabled: true
    user: ${SPRING_FLYWAY_USER}
    password: ${SPRING_FLYWAY_PASSWORD}
    default-schema: ${DB_SCHEMA:auth}

  lifecycle:
    timeout-per-shutdown-phase: 30s

server:
  port: ${SERVER_PORT:8081}
  shutdown: graceful

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    health:
      probes:
        enabled: true # required for Kubernetes liveness/readiness probes
      show-details: when-authorized

logging:
  level:
    root: ${LOG_LEVEL:INFO}

# JWT configuration
jwt:
  secret: ${JWT_SECRET}
  access-token-ttl: ${JWT_ACCESS_TOKEN_TTL:PT15M}
  refresh-token-ttl: ${JWT_REFRESH_TOKEN_TTL:P7D}

# SpringDoc — disabled by default, enabled in dev
springdoc:
  swagger-ui:
    enabled: ${SWAGGER_ENABLED:false}
  api-docs:
    enabled: ${SWAGGER_ENABLED:false}
```

### Required `pom.xml` Dependencies

```xml
<!-- Actuator — health endpoints, metrics -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>

<!-- Prometheus metrics -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>

<!-- Database -->
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
    <scope>runtime</scope>
</dependency>

<!-- Migrations -->
<dependency>
    <groupId>org.flywaydb</groupId>
    <artifactId>flyway-core</artifactId>
</dependency>
<dependency>
    <groupId>org.flywaydb</groupId>
    <artifactId>flyway-database-postgresql</artifactId>
</dependency>
```

### Why `server.shutdown: graceful`

Combined with `spring.lifecycle.timeout-per-shutdown-phase: 30s`, this lets Spring drain in-flight requests before exiting on SIGTERM. Without it, in-flight requests get aborted mid-flight when Kubernetes terminates the pod.

The 30s graceful shutdown fits inside Kubernetes' default 30s grace period — by the time K8s would send SIGKILL, Spring has already cleanly exited.

---

## Minikube — Local Setup & Deployment

### Why Minikube Is for Learning Only

- GitHub Actions cannot reach your laptop → CD pipeline cannot deploy here
- It's a single-node cluster — no real HA, scheduling, or network policy testing
- The manifests you write here translate directly to EKS with environment-specific patches

### One-Time Setup

```bash
# Install (macOS)
brew install minikube kubectl

# Verify Docker Desktop is running
docker ps

# Configure Docker Desktop memory (Settings → Resources)
# • If 8GB Mac: Docker memory = 6GB
# • If 16GB+ Mac: Docker memory = 10GB+

# Start minikube with resources sized for your Mac
# 8GB Mac:
minikube start --cpus=2 --memory=4096 --driver=docker

# 16GB+ Mac:
minikube start --cpus=4 --memory=8192 --driver=docker

# Verify
minikube status
kubectl get nodes
kubectl get pods -A

# Enable required addons
minikube addons enable ingress           # NGINX Ingress controller
minikube addons enable metrics-server    # Required for HPA
```

### Per-Deploy Setup

```bash
# 1. Replace real secret values in dev overlay
# Generate JWT secret
openssl rand -base64 48
# Edit k8s/overlays/dev/auth-service/secrets.yaml with real values

# 2. Generate self-signed TLS cert for auth.local
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout auth-tls.key \
  -out auth-tls.crt \
  -subj "/CN=auth.local/O=auth-local" \
  -addext "subjectAltName = DNS:auth.local"

# Create namespace first (idempotent)
kubectl create namespace auth-service --dry-run=client -o yaml | kubectl apply -f -

# Create TLS secret
kubectl create secret tls auth-tls \
  --cert=auth-tls.crt \
  --key=auth-tls.key \
  --namespace=auth-service

# Clean up
rm auth-tls.crt auth-tls.key

# 3. Add auth.local to /etc/hosts
echo "$(minikube ip) auth.local" | sudo tee -a /etc/hosts
```

### Deploy

```bash
# Preview what will be applied
kubectl kustomize k8s/overlays/dev/auth-service

# Apply
kubectl apply -k k8s/overlays/dev/auth-service

# Watch rollout
kubectl get pods -n auth-service -w

# Once pods are Ready:
curl -k https://auth.local/actuator/health
# -k skips self-signed cert validation
```

### Useful Operational Commands

```bash
# View what's running
kubectl get all -n auth-service

# Tail logs
kubectl logs -n auth-service -l app.kubernetes.io/name=auth-service --tail=100 -f

# Shell into running pod
kubectl exec -it -n auth-service \
  $(kubectl get pod -n auth-service -l app.kubernetes.io/name=auth-service -o jsonpath='{.items[0].metadata.name}') \
  -- sh

# Restart a Deployment (force new pods)
kubectl rollout restart deployment/auth-service -n auth-service

# Roll back to previous version
kubectl rollout undo deployment/auth-service -n auth-service

# View rollout history
kubectl rollout history deployment/auth-service -n auth-service

# Connect to Postgres
kubectl exec -it -n auth-service postgres-0 -- psql -U appuser -d spring_ref_db

# View resource usage (requires metrics-server)
kubectl top pods -n auth-service

# Clean up everything
kubectl delete namespace auth-service
# Or: minikube delete (nukes the whole cluster)
```

---

## GitHub Environments & Approval Gates

### Configuration

In **Settings → Environments**, create three environments:

| Environment | Protection rules                                    | Reviewers  |
| ----------- | --------------------------------------------------- | ---------- |
| `dev`       | None                                                | None       |
| `staging`   | None                                                | None       |
| `prod`      | Required reviewers + deployment branch: `main` only | Team leads |

The CD workflow's `environment:` key triggers these rules automatically.

### How the Approval Flow Works

```
You: workflow_dispatch → environment=prod
   │
   ▼
GitHub Actions starts CD job
   │
   ▼
Job reaches deploy step (environment: prod)
   │
   ▼
Job pauses with status: "Waiting for approval"
   │
   │ ← Reviewer sees in GitHub UI:
   │   • Workflow name
   │   • Triggered by: you
   │   • Image tag being deployed
   │   • Source commit SHA
   │   • Diff of manifest changes
   │
   ▼ Reviewer clicks "Approve"
Job continues, deploys to prod
```

The reviewer sees the exact change before approving. This is the audit trail and the safety gate.

---

## Adding a New Microservice

Worked example: adding `order-service`.

### 1. Create Service Directory

```
services/order-service/
├── pom.xml
├── Dockerfile
├── Makefile
├── .envrc.example
└── src/
```

Copy structure from `auth-service`, adapt the Java package and DB schema.

### 2. Copy CI Caller

```bash
cp .github/workflows/ci-auth-service.yml .github/workflows/ci-order-service.yml
```

Edit:

- `name:` → `CI — order-service`
- `paths:` → `services/order-service/**`
- `service-name:` → `order-service`
- `service-dir:` → `services/order-service`

### 3. Copy CD Caller

```bash
cp .github/workflows/cd-auth-service.yml .github/workflows/cd-order-service.yml
```

Same edits as CI caller, plus update the secrets passed through.

### 4. Copy Kustomize Base

```bash
cp -r k8s/base/auth-service k8s/base/order-service
```

Sed-replace all occurrences of `auth-service` → `order-service` in every file:

```bash
find k8s/base/order-service -type f -name '*.yaml' -exec \
  sed -i '' 's/auth-service/order-service/g' {} \;
```

Then audit manually:

- DB name (`spring_ref_db` → maybe `order_db`?)
- Schema (`auth` → `orders`)
- Image URL (`auth-service` → `order-service` in ECR repo URL)
- Ingress hostname placeholder

### 5. Copy Dev Overlay

```bash
cp -r k8s/overlays/dev/auth-service k8s/overlays/dev/order-service
# Same sed replace as above
```

Repeat for staging/prod overlays when those clusters are set up.

### 6. Update Dependabot

Add a new entry to `.github/dependabot.yml`:

```yaml
- package-ecosystem: maven
  directory: "/services/order-service"
  schedule:
    interval: weekly
    day: monday
```

### 7. Update Nightly Security Scan

Add `order-service` to the matrix in `.github/workflows/scheduled-security-scan.yml`:

```yaml
strategy:
  matrix:
    service:
      - auth-service
      - order-service
```

### 8. Create ECR Repo

```bash
aws ecr-public create-repository --repository-name order-service
```

### 9. Configure Branch Protection

In **Settings → Branches → main**, require `PR Check — order-service` as a status check.

That's it. The new service is wired into CI, CD, security scanning, dependency surveillance, and Kubernetes deployment.

---

## AWS Migration Guide (Minikube → EKS)

### Phase 1: One-Time Infrastructure Setup

These are done once per environment (dev, staging, prod) using Terraform or eksctl. Not part of the CD pipeline.

```bash
# Create EKS cluster (eksctl example)
eksctl create cluster \
  --name auth-platform-dev \
  --region eu-central-1 \
  --node-type t3.medium \
  --nodes 2 \
  --version 1.30
```

**Cluster-level setup**:

- IAM OIDC provider for IRSA
- AWS Load Balancer Controller (for ALB ingress)
- Secrets Store CSI driver + AWS provider
- External-DNS (optional, for automatic Route 53 records)
- Cert-manager (if using Let's Encrypt; not needed if using ACM)
- Cluster Autoscaler / Karpenter

**Per-service IRSA setup**:

```bash
# Create IAM role for the auth-service pod to access AWS Secrets Manager
eksctl create iamserviceaccount \
  --cluster auth-platform-dev \
  --namespace auth-service \
  --name auth-service \
  --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
  --approve
```

### Phase 2: Migrating the Pipeline

The Kustomize manifests and CD workflow are ~90% reusable. Concrete changes:

#### CD Workflow: AWS Authentication

```yaml
# Replace Docker Hub login (if you ever had one) with OIDC-based AWS auth
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-deploy
    aws-region: ${{ secrets.AWS_REGION }}

# Get cluster credentials (replaces base64 kubeconfig)
- name: Update kubeconfig
  run: aws eks update-kubeconfig --name auth-platform-${{ inputs.environment }} --region ${{ secrets.AWS_REGION }}
```

The `KUBECONFIG_DEV`/`KUBECONFIG_STAGING`/`KUBECONFIG_PROD` GitHub Secrets are replaced by an OIDC trust relationship between GitHub Actions and an IAM role. More secure (no long-lived credentials), easier rotation.

#### Image Source: ECR Public → ECR Private (Optional)

When the service stops being a public template and becomes proprietary:

```bash
# Create ECR Private repo
aws ecr create-repository --repository-name auth-service --region eu-central-1
```

Update Deployment image reference:

```
public.ecr.aws/o6c1v8x2/auth-service:tag
       ↓
<account>.dkr.ecr.eu-central-1.amazonaws.com/auth-service:tag
```

EKS nodes need ECR pull permissions. Add to the node group's IAM role:

- `AmazonEC2ContainerRegistryReadOnly` (managed policy)

No `imagePullSecret` needed — EKS nodes inherit ECR pull capability from their node IAM role.

#### Ingress: NGINX → ALB

Replace in overlay's `patch-ingress.yaml`:

```yaml
# Old (minikube/NGINX)
metadata:
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx

# New (EKS/ALB)
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:eu-central-1:...
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  ingressClassName: alb
```

#### Database: In-Cluster Postgres → RDS

Replace in overlay:

1. **Remove** `postgres-statefulset.yaml` and `postgres-service.yaml` from overlay's kustomization (use a patch to delete, or split base resources differently)
2. **Update ConfigMap** with RDS endpoint:
   ```yaml
   DB_HOST: auth-platform-prod-db.cxxxxxxxx.eu-central-1.rds.amazonaws.com
   ```
3. **Remove** the initContainer waiting for in-cluster Postgres
4. **Update** Secret source to AWS Secrets Manager (where RDS password is stored)

#### Secrets: kubectl-applied → AWS Secrets Manager

Replace the gitignored `secrets.yaml` with `SecretProviderClass`:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: auth-service-secrets
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "prod/auth-service/db-password"
        objectType: "secretsmanager"
      - objectName: "prod/auth-service/jwt-secret"
        objectType: "secretsmanager"
  secretObjects:
    - secretName: auth-service-secrets
      type: Opaque
      data:
        - objectName: "prod/auth-service/db-password"
          key: SPRING_DATASOURCE_PASSWORD
        - objectName: "prod/auth-service/jwt-secret"
          key: JWT_SECRET
```

The Deployment references `auth-service-secrets` the same way. The CSI driver populates it from AWS at pod startup.

### Per-Environment Overlay Differences (EKS)

| Concern             | dev                  | staging                  | prod                     |
| ------------------- | -------------------- | ------------------------ | ------------------------ |
| Cluster             | `auth-platform-dev`  | `auth-platform-staging`  | `auth-platform-prod`     |
| Replicas            | 1                    | 2                        | 3+                       |
| Resource limits     | 512Mi / 500m         | 1Gi / 1000m              | 2Gi / 2000m              |
| RDS instance class  | t3.micro             | t3.small                 | t3.medium (multi-AZ)     |
| Ingress hostname    | auth.dev.example.com | auth.staging.example.com | auth.example.com         |
| TLS cert            | ACM (Let's Encrypt)  | ACM                      | ACM                      |
| PodDisruptionBudget | No                   | minAvailable: 1          | minAvailable: 2          |
| Anti-affinity       | None                 | Soft                     | Hard (spread across AZs) |
| HPA max replicas    | 1                    | 4                        | 10                       |
| Log level           | DEBUG                | INFO                     | INFO                     |

### Migration Order

1. **Set up dev EKS cluster** with all the cluster-level addons
2. **Migrate dev overlay** — update for ALB, RDS, IRSA
3. **Run CD against dev EKS** — verify the pipeline works against a real cluster
4. **Set up staging EKS** — repeat
5. **Set up prod EKS** — add PodDisruptionBudget, anti-affinity, HPA scaled up
6. **Configure GitHub Environment "prod"** with required reviewers
7. **Final cutover**: switch production DNS to point at EKS ALB

---

## Observability — What to Add Next

The pipeline exposes metrics and logs but doesn't yet collect them. Recommended stack:

| Concern | Tool                  | Setup                                                |
| ------- | --------------------- | ---------------------------------------------------- |
| Metrics | Prometheus + Grafana  | Spring Boot auto-exposes `/actuator/prometheus`      |
| Logs    | Loki + Promtail       | JSON logs from container stdout                      |
| Traces  | Tempo + OpenTelemetry | Add `spring-boot-starter-actuator` + OTel agent      |
| Alerts  | Alertmanager          | Wire to PagerDuty/Slack                              |
| GitOps  | ArgoCD or Flux        | Replace `kubectl apply` in CD with Git commit + sync |

### Quick Minikube Observability Setup

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace

# Access Grafana
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# Default credentials: admin / prom-operator
```

### Production Observability Decisions

For EKS prod, consider:

- **AWS Managed Prometheus + Grafana** — no infrastructure to manage
- **AWS CloudWatch Logs Insights** — already wired up via Container Insights addon
- **AWS X-Ray** — built-in distributed tracing, integrates with Spring via the X-Ray SDK
- **Datadog or New Relic** — if your org standardizes on a commercial APM

---

## Operational Runbook

### Common Tasks

#### Deploy to dev (auto, on merge)

Nothing to do — CD runs automatically. Watch the workflow run.

#### Deploy specific tag to staging

```bash
gh workflow run "CD — auth-service" \
  -f environment=staging \
  -f image-tag=dev-abc1234
```

Or via UI: Actions → CD — auth-service → Run workflow.

#### Roll back prod to previous version

**Method 1** (kubectl, fast):

```bash
# Get history
kubectl rollout history deployment/auth-service -n auth-service

# Roll back to previous
kubectl rollout undo deployment/auth-service -n auth-service

# Roll back to specific revision
kubectl rollout undo deployment/auth-service -n auth-service --to-revision=3
```

**Method 2** (CD pipeline, traceable):

```bash
gh workflow run "CD — auth-service" \
  -f environment=prod \
  -f image-tag=<previous-good-sha>
```

#### Investigate a crashing pod

```bash
# What's the status?
kubectl get pod <pod-name> -n auth-service

# Last reason it died
kubectl describe pod <pod-name> -n auth-service | grep -A 5 "Last State"

# Logs (current container)
kubectl logs <pod-name> -n auth-service

# Logs (previous crashed container)
kubectl logs <pod-name> -n auth-service --previous

# Events in the namespace
kubectl get events -n auth-service --sort-by='.lastTimestamp' | tail -20
```

#### Update a Secret without restarting pods

Secret changes don't auto-restart pods by default. Force a rollout:

```bash
# Update the secret
kubectl create secret generic postgres-credentials \
  --from-literal=POSTGRES_PASSWORD=newpassword \
  --namespace=auth-service \
  --dry-run=client -o yaml | kubectl apply -f -

# Trigger a rolling restart
kubectl rollout restart deployment/auth-service -n auth-service
```

### Failure Modes

| Symptom                               | Likely cause                         | Fix                                                          |
| ------------------------------------- | ------------------------------------ | ------------------------------------------------------------ |
| Pod stuck `ImagePullBackOff`          | Wrong image tag, registry auth issue | Check `kubectl describe pod` for specific error              |
| Pod stuck `CrashLoopBackOff`          | App crashes on startup               | `kubectl logs <pod> --previous` to see why                   |
| Pod `OOMKilled`                       | Memory limit too low                 | Bump `resources.limits.memory`, redeploy                     |
| `kubectl apply` hangs                 | Webhook timeout                      | Check ingress-nginx admission webhook is running             |
| Ingress returns 503                   | No healthy pods                      | `kubectl get pods` — are they Ready?                         |
| Ingress returns 404                   | Wrong hostname or path               | Check Ingress spec and DNS resolution                        |
| Flyway migration fails                | Schema state corrupted               | `kubectl exec` into pod, check `flyway_schema_history` table |
| CD pipeline fails at `rollout status` | New pod can't reach Ready            | Liveness/readiness probe failing — check probe config        |

---

## Decision Log

### Why ECR Public Instead of Docker Hub

- Free (storage + egress)
- Same AWS account as future EKS deployment
- Anonymous pull works for minikube — no credential plumbing
- **Caveat**: anyone can pull the image, so no secrets in layers, no proprietary IP

### Why ECR Public Instead of ECR Private (for now)

This is a template/learning project. Public is appropriate. **Migration plan**:

- When this becomes a production service with proprietary code → move to ECR Private
- EKS nodes get pull permissions via node IAM role (no per-pod credential)
- Minikube would need an IAM user + `imagePullSecret` refresh — only worth the complexity for real prod

### Why Kustomize Over Helm

- No templating language (just YAML merging)
- Built into kubectl
- Easier debugging — `kubectl kustomize` shows exactly what gets applied
- Trade-off: less flexibility than Helm for complex parameterization

For a 3-environment monorepo, Kustomize is the right tool. For shipping a chart to external users, Helm wins.

### Why Manual Minikube Instead of CD-to-Minikube

- GitHub Actions can't reach a laptop on home/office NAT
- Minikube is for iteration; CD is for standardization
- The manifests transfer 1:1 to real EKS, so the learning is reusable

### Why Move OWASP and Semgrep Off PRs

- They were `continue-on-error: true` — running but not enforcing
- ~15 min added to PR turnaround time without preventing anything
- Same coverage from nightly schedule + Dependabot continuous monitoring
- Findings flow to GitHub Security tab, triaged centrally instead of per-PR

### Why CodeQL Stays on PRs

- Fast enough (~5 min on a small Java service)
- Diff-aware: analyzes the changed paths, not the full codebase
- Catches code-level issues that should block merge (SQL injection, hardcoded creds)
- Genuine value gate, not a "report and continue" pattern

### Why Pin Postgres and Tomcat Versions in pom.xml

- Spring Boot's release cadence lags behind upstream CVE patches by weeks
- Overriding gives you a same-day fix when CVEs are published
- **Remove the override** once Spring Boot ships a release with the patched version

### Why InitContainer for Postgres Wait

- Spring Boot crashes hard if DB is unreachable at startup
- CrashLoopBackOff has exponential backoff — pod stays down 5+ minutes after first crash
- InitContainer with `pg_isready` polls cheaply, only proceeds when DB is up
- Cost: ~30 MB extra image (cached after first pull)

### Why `exec` in ENTRYPOINT

- Without it, `sh` is PID 1 and doesn't forward SIGTERM
- JVM gets SIGKILLed after grace period, losing in-flight requests
- 4 characters of fix prevents an entire class of production bugs

---

_Last updated: 2026-05-31. Update this doc when making architectural changes._
