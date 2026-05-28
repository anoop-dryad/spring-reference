<h1 align="center">
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/spring/spring-original.svg" 
       width="45"
       style="vertical-align: middle; margin-right: 10px;" />
  <span style="vertical-align: middle;">
    SPRING BOOT REFERENCE PROJECT
  </span>
</h1>

<h3 align="center">
A Production Ready JWT-based authentication service built with Spring Boot 4, PostgreSQL, and Flyway.
Secure • Scalable • Clean • Environment-Aware • Simple
</h3>

<p align="center">
Stop rewriting authentication, security, and configuration logic in every new project.  
Start with a solid, production-grade backend foundation. A modern backend foundation with JWT, CI/CD, Docker, Makefile.  
so you never start from scratch again.
</p>
<p align="center">

<img src="https://img.shields.io/github/last-commit/yuosef33/Spring-boot-starter-template?color=blue&style=flat" />
<img src="https://img.shields.io/github/languages/top/yuosef33/Spring-boot-starter-template?style=flat" />
<img src="https://img.shields.io/github/languages/count/yuosef33/Spring-boot-starter-template?style=flat" />
<img src="https://img.shields.io/badge/Java-21-red?style=flat&logo=openjdk" />
<img src="https://img.shields.io/badge/Spring%20Boot-4.x-brightgreen?style=flat&logo=springboot" />
</p>

---


# Auth Service

JWT-based authentication service built with Spring Boot 4, PostgreSQL, and Flyway.

---

## Tech Stack

| Technology | Purpose |
|------------|---------|
| Spring Boot 4 | Application framework |
| Spring Security 7 | Authentication & authorization |
| PostgreSQL | Database |
| Flyway | Database migrations |
| JJWT 0.13 | JWT token generation & validation |
| SpringDoc OpenAPI 3 | API documentation |
| Docker | Containerization |
| Docker Hub | Container registry |
| Kubernetes (minikube → EKS) | Orchestration |
| GitHub Actions | CI/CD |

---

## Prerequisites

- Java 21 (via [sdkman](https://sdkman.io/): `sdk install java 21.0.11-amzn`)
- Maven 3.9+
- PostgreSQL 16+
- Docker Desktop
- [direnv](https://direnv.net/) (`brew install direnv`)
- minikube + kubectl (for cluster deploys)

---

## Getting Started

### 1. Database Setup

Follow [DATABASE_SETUP.md](../DATABASE_SETUP.md) to create the database, schema, and users.

Quick summary:
```bash
# copy and fill in credentials
cp .envrc.example .envrc

# load environment variables
direnv allow

# run setup script
./setup_db.sh
```

### 2. Environment Variables

Your `.envrc` should contain:
```bash
export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME=spring_ref_db
export DB_SCHEMA=auth
export DB_APP_USER=appuser
export DB_APP_PASSWORD=your_password
export DB_FLYWAY_USER=flyuser
export DB_FLYWAY_PASSWORD=your_password
export JWT_SECRET=your_secret_key_minimum_32_characters
export JWT_EXPIRATION_MS=86400000
```

### 3. Run the Application

```bash
make run
```

The app starts on `http://localhost:8081`.

---

## Makefile Commands

```bash
make help           # list all available commands
make build          # build jar, skip tests
make build-full     # build jar with tests
make run            # run locally with Maven
make test           # run tests
make clean          # clean target directory
make docker-build   # build Docker image
make docker-run     # run in Docker container
make docker-stop    # stop and remove container
make docker-logs    # tail container logs
make db-setup       # run database setup script
make db-migrate     # run Flyway migrations manually
make db-info        # show migration status
make db-validate    # validate migrations
```

---

## Database Migrations (Flyway)

Migrations are managed by [Flyway](https://flywaydb.org/) and run automatically on app startup.

### Migration Files

Place migration files in:
```
src/main/resources/db/migration/
```

### Naming Convention

```
V{version}__{description}.sql
```

| Prefix | Purpose |
|--------|---------|
| `V1__description.sql` | Versioned — runs once, in order |
| `R__description.sql` | Repeatable — re-runs when checksum changes |

Example:
```
V1__create_users_table.sql
V2__add_refresh_tokens_table.sql
```

### Manual Migration Commands

```bash
make db-info        # check current migration status
make db-validate    # validate checksums against DB
make db-migrate     # run pending migrations manually
```

### Two-User Strategy

| User | Role | Privileges |
|------|------|------------|
| `flyuser` | Flyway migration user | DDL — CREATE, ALTER, DROP |
| `appuser` | App runtime user | DML — SELECT, INSERT, UPDATE, DELETE |

The app runtime never has DDL privileges — schema changes only happen through Flyway.

---

## API Documentation (SpringDoc / Swagger UI)

Swagger UI is available in development at:

```
http://localhost:8081/swagger-ui.html
http://localhost:8081/v3/api-docs
```

> ⚠️ Swagger UI is disabled by default in production.
> Set `SWAGGER_ENABLED=true` in your environment to enable it locally.

```bash
# .envrc — enable swagger in dev
export SWAGGER_ENABLED=true
```

```yaml
# application.yml
springdoc:
  swagger-ui:
    enabled: ${SWAGGER_ENABLED:false}
  api-docs:
    enabled: ${SWAGGER_ENABLED:false}
```

---

## Docker

### Build Image

```bash
make docker-build
```

### Run Container

Create a `.env` file (Docker format, no `export` prefix):
```bash
DB_HOST=host.docker.internal
DB_PORT=5432
DB_NAME=spring_ref_db
DB_APP_USER=appuser
DB_APP_PASSWORD=your_password
DB_FLYWAY_USER=flyuser
DB_FLYWAY_PASSWORD=your_password
JWT_SECRET=your_secret_key_minimum_32_characters
JWT_EXPIRATION_MS=86400000
```

> `.env` is gitignored — never commit it.

```bash
make docker-run     # start container
make docker-logs    # tail logs
make docker-stop    # stop and remove container
```

### Dockerfile Highlights

- Base image: `eclipse-temurin:21-jre-alpine` (~180MB)
- Multi-stage build with Spring Boot layer extraction for fast rebuilds
- Runs as a non-root system user for security
- Uses `/dev/urandom` entropy source to prevent startup hangs
- Healthcheck via `/actuator/health`
- `exec` entrypoint so the JVM is PID 1 (clean SIGTERM handling for Kubernetes)

---

## Deploying to Minikube

For local Kubernetes development the service runs in minikube. AWS EKS is the target for staging/prod (see [CI/CD Pipeline](#cicd-pipeline)).

### One-time minikube setup

```bash
# Start minikube with enough resources for Spring Boot + Postgres
minikube start --cpus=4 --memory=8192 --driver=docker

# Enable required addons
minikube addons enable ingress
minikube addons enable metrics-server
```

### Deploying the service

**Option A — Build directly into minikube (no registry round-trip)**

```bash
# Point your shell's docker at minikube's daemon
eval $(minikube docker-env)

# Build — the image lands inside minikube, not on your host
make docker-build

# Apply manifests
kubectl apply -f k8s/dev/
```

The Deployment uses `imagePullPolicy: Never` so Kubernetes uses the locally-built image rather than pulling from Docker Hub. Fastest iteration loop for local work.

**Option B — Pull from Docker Hub**

```bash
# Image must already be pushed (CD does this automatically on main merges)
kubectl apply -f k8s/dev/
```

Use this path when you want to verify the exact image that CI/CD produced, or when collaborating with someone who doesn't have your local source checkout.

### Creating secrets in the cluster

For local minikube, generate Kubernetes Secrets from your `.env`:

```bash
kubectl create namespace auth-service
kubectl create secret generic auth-service-secrets \
  --from-env-file=.env \
  --namespace=auth-service
```

For staging/prod (later, on EKS), secrets are sourced from AWS Secrets Manager via the Secrets Store CSI driver — the Deployment manifests stay the same.

### Accessing the service

```bash
# Port-forward to localhost
kubectl port-forward -n auth-service svc/auth-service 8081:8081

# Or expose via minikube
minikube service auth-service -n auth-service
```

### Useful commands

```bash
# Watch pod status
kubectl get pods -n auth-service -w

# Tail logs
kubectl logs -n auth-service -l app=auth-service --tail=100 -f

# Describe a failing pod
kubectl describe pod -n auth-service <pod-name>

# Shell into a running container
kubectl exec -it -n auth-service <pod-name> -- sh

# Check rollout status after deploy
kubectl rollout status -n auth-service deployment/auth-service
```

---

## CI/CD Pipeline

CI and CD are split into separate workflows using **GitHub Actions**. PR validation runs on every pull request; deployments fire on merge to `main` (auto-dev) and on manual dispatch (staging/prod).

```
.github/
├── dependabot.yml                              ← continuous dependency CVE watch
└── workflows/
    ├── ci-auth-service.yml                     ← per-service caller (PR trigger)
    ├── reusable-java-pr-check.yml              ← shared PR-check logic (fast)
    └── scheduled-security-scan.yml             ← nightly heavy scans (OWASP, full Semgrep)
```

### Workflow files

| File | Purpose | Trigger |
|---|---|---|
| `.github/workflows/ci-auth-service.yml` | PR validation (build, test, lint) | PRs touching `auth-service/**` |
| `.github/workflows/cd-auth-service.yml` | Build image and deploy | `main` merge (auto-dev), `workflow_dispatch` (staging/prod) |
| `.github/workflows/reusable-java-pr-check.yml` | Shared PR-check logic | Called by CI workflows |
| `.github/workflows/reusable-java-cd.yml` | Shared CD logic | Called by CD workflows |

### CI flow (every PR)

1. Checkout the branch
2. Set up JDK 21 with Maven dependency cache
3. Compile the project
4. Run unit and integration tests (Testcontainers brings up Postgres)
5. Generate JaCoCo coverage report
6. Upload artifacts — test results, coverage, scan reports

Security scans (OWASP Dependency-Check, Semgrep) can be re-enabled when ready — they're currently disabled in the reusable PR-check workflow.

### CD flow (merge to main)

```
main merge (auth-service/** changed)
        ↓
build JAR (Maven)
        ↓
build multi-arch Docker image (linux/amd64 + linux/arm64)
        ↓
push to Docker Hub
        ↓
kubectl apply to dev cluster
        ↓
verify rollout (kubectl rollout status)
```

### Promotion model

| Environment | Trigger | Approval |
|---|---|---|
| **dev** | Auto on merge to `main` | None |
| **staging** | Manual via `workflow_dispatch` | None |
| **prod** | Manual via `workflow_dispatch` | GitHub Environment approval required |

Production deploys are gated by a GitHub Environment with required reviewers — the deploy job pauses until a designated approver clicks "Approve."

### Docker Hub configuration

Images are published to Docker Hub:

```
docker.io/<dockerhub-org>/auth-service:<tag>
```

**Tagging strategy:**

| Tag | When applied |
|---|---|
| `latest` | Latest successful build from `main` |
| `<git-sha>` | Every build — immutable, used for promotion between envs |
| `<semver>` | Tagged releases (e.g., `1.4.2`) |
| `dev` / `staging` / `prod` | Floating tags pointing to whatever's currently deployed per environment |

**Promotion between environments uses the immutable SHA tag**, never `latest`. This guarantees that what's tested in staging is byte-identical to what's deployed to prod.

### Required GitHub Secrets

Configured at **Repo Settings → Secrets and variables → Actions**:

| Secret | Used by | Description |
|---|---|---|
| `DOCKERHUB_USERNAME` | CD | Docker Hub account/org name |
| `DOCKERHUB_TOKEN` | CD | Docker Hub access token (not password) |
| `KUBECONFIG_DEV` | CD | Base64-encoded kubeconfig for dev cluster |
| `KUBECONFIG_STAGING` | CD | Base64-encoded kubeconfig for staging cluster |
| `KUBECONFIG_PROD` | CD | Base64-encoded kubeconfig for prod cluster |

Generate a Docker Hub token at `hub.docker.com → Account Settings → Security → New Access Token`. Use scoped read/write permissions — never the account password.

Encode a kubeconfig for use as a secret:

```bash
cat ~/.kube/config | base64 | pbcopy   # macOS
cat ~/.kube/config | base64 -w 0       # Linux
```

### Manually triggering a deploy

From the GitHub UI: **Actions → CD — auth-service → Run workflow**, then pick the environment and optionally a specific image tag.

From the CLI:

```bash
gh workflow run "CD — auth-service" \
  -f environment=staging \
  -f image-tag=abc1234
```

### Why CD might not trigger on merge

The CD workflow has a `paths:` filter — only changes under `auth-service/**` trigger an auto-deploy. README updates, workflow edits, and other non-code changes won't redeploy the service. Use `workflow_dispatch` if you need to force a deploy without a code change.

### Rolling back

```bash
# View deployment history
kubectl rollout history -n auth-service deployment/auth-service

# Roll back to previous revision
kubectl rollout undo -n auth-service deployment/auth-service

# Or deploy a specific older SHA
gh workflow run "CD — auth-service" \
  -f environment=prod \
  -f image-tag=<previous-good-sha>
```

---

## API Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/auth/login` | None | Authenticate and get JWT token |
| `GET` | `/actuator/health` | None | Health check |

---

## Troubleshooting

**`Connection refused` in Docker**
PostgreSQL is running on your host, not inside the container. Set `DB_HOST=host.docker.internal` in `.env`.

**`Flyway permission denied for schema auth`**
The Flyway user doesn't have the right privileges. Re-run `./setup_db.sh` or see [DATABASE_SETUP.md](../DATABASE_SETUP.md).

**`role "${DB_APP_USER}" does not exist`**
Environment variables are not loaded. Run `direnv allow` or export them manually.

**Swagger UI not loading**
Make sure `SWAGGER_ENABLED=true` is set and you're hitting the right port (`8081`).

**App hangs on startup in Docker**
The `/dev/urandom` flag in the Dockerfile should prevent this. If still occurring, check your Docker resource limits.

**Pod stuck in `ImagePullBackOff` on minikube**
Did you `eval $(minikube docker-env)` before building? Without it, the image goes to your host's Docker daemon rather than minikube's, and Kubernetes inside minikube can't find it.

**Pod crash-loops with `OutOfMemoryError`**
Heap is sized as a percentage of the container memory limit (`-XX:MaxRAMPercentage=75.0`). If the Deployment's `resources.limits.memory` is too low, the heap is too small. Bump the limit or lower the percentage.

**CD workflow didn't trigger on merge**
The `paths:` filter only auto-deploys when files under `auth-service/**` change. Doc-only or workflow-only PRs are skipped by design — use `workflow_dispatch` to deploy without a code change.

**JWT validation fails between services**
`JWT_SECRET` must be at least 256 bits (32+ chars) and **identical** across the issuer (this service) and any downstream service validating the token. A mismatch produces opaque `SignatureException` errors.
