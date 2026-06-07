# spring-reference

> A production grade monorepo for Spring Boot microservices with CI/CD, Kubernetes deployment, and AWS EKS migration path.

The current reference service is **auth-service** — a JWT-based authentication service using Spring Boot 4, PostgreSQL 16, and Flyway migrations.

---

## Quick Start

```bash
# Prerequisites: Java 21, Maven, Docker Desktop, minikube, kubectl, openssl

# 1. Build and run locally
cd auth-service
./mvnw spring-boot:run

# 2. OR deploy to local Kubernetes (minikube)
minikube start --cpus=2 --memory=4096 --driver=docker
minikube addons enable ingress metrics-server
kubectl apply -k k8s/overlays/dev/auth-service

# 3. Set up TLS + ingress (see docs/CERTIFICATE-TLS-README.md and docs/NETWORKING-README.md)
```

For full setup, see the documentation below.

---

## Documentation

| Document                                                                 | When to read it                                                                         |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| [docs/DATABASE-SETUP-README.md](./DATABASE-SETUP-README.md)              | Setting up Postgres locally for direct Spring Boot development                          |
| [docs/CI-CD-ARCHITECTURE-README.md](./docs/CI-CD-ARCHITECTURE-README.md) | Understanding the full pipeline — CI, CD, image registry, Kustomize, EKS migration path |
| [docs/NETWORKING-README.md](./docs/NETWORKING-README.md)                 | How traffic flows from your browser to a Spring Boot pod, debugging connectivity issues |
| [docs/CERTIFICATE-TLS-README.md](./docs/CERTIFICATE-TLS-README.md)       | Certificate handling — self-signed for dev, Let's Encrypt / ACM for production          |
| [docs/OBSERVABILITY.md](./docs/OBSERVABILITY.md)                         | Setting up Prometheus + Grafana, instrumenting code, building dashboards                |

---

## Repository Structure

```
spring-reference/
│
├── .github/
│   ├── dependabot.yml                          # Dependency CVE surveillance
│   └── workflows/
│       ├── reusable-java-pr-check.yml          # CI: PR checks (tests + CodeQL)
│       ├── reusable-java-cd.yml                # CD: build, push, deploy
│       ├── scheduled-security-scan.yml         # Nightly OWASP + full Semgrep
│       ├── ci-auth-service.yml                 # Per-service CI caller
│       └── cd-auth-service.yml                 # Per-service CD caller
│
├── auth-service/                               # Spring Boot service
│   ├── pom.xml
│   ├── Dockerfile                              # Multi-stage build, multi-arch
│   ├── Makefile                                # Dev convenience targets
│   └── src/
│       ├── main/java/com/anpks/auth/
│       ├── main/resources/
│       │   ├── application.yaml
│       │   └── db/migration/                   # Flyway migrations
│       └── test/
│
├── k8s/                                        # Kubernetes manifests
│   ├── base/auth-service/                      # Env-agnostic resources
│   └── overlays/
│       ├── dev/auth-service/                   # Minikube
│       ├── staging/auth-service/               # AWS EKS staging (TBD)
│       └── prod/auth-service/                  # AWS EKS prod (TBD)
│
├── docs/
│   ├── CI-CD-ARCHITECTURE-README.md            # Full pipeline reference
│   ├── DATABASE-SETUP-README.md                # Local Postgres setup
│   ├── NETWORKING-README.md                    # Network topology + troubleshooting
│   └── CERTIFICATE-TLS-README.md               # Certificate handling
|
├── scripts/
│   ├── postgres_setup.sql                      # postgres local db setup with app and flywadb user and access
│   ├── setup_db.sh                             # script to invoke db script
|
├── .gitignore
├── .envrc                                      # env values
├── Makefile                                    # global makefile
└── README.md
```

---

## Tech Stack

### Application

- **Java 21** with Spring Boot 4
- **PostgreSQL 16** with Flyway for schema migrations
- **JJWT 0.13** for token signing
- **SpringDoc OpenAPI** for API documentation (Swagger UI in dev)

### Build & Image

- **Maven** with dependency caching
- **Multi-stage Dockerfile** with Spring Boot layer extraction
- **Multi-arch images** (linux/amd64 + linux/arm64) for Apple Silicon and AWS Graviton
- **ECR Public** as the image registry (`public.ecr.aws/o6c1v8x2/auth-service`)

### CI/CD

- **GitHub Actions** for CI and CD
- **CodeQL** for SAST on every PR (fast, blocking)
- **OWASP Dependency-Check + Semgrep** nightly (comprehensive, off PR path)
- **Dependabot** for continuous dependency CVE surveillance
- **Multi-arch builds** in CD via Docker buildx

### Deployment

- **Kustomize** for environment overlays (no Helm)
- **Local**: minikube with NGINX Ingress + self-signed TLS
- **Target**: AWS EKS with ALB Ingress + ACM certificates
- **HPA** for autoscaling (configured per environment)

---

## Daily Workflow

### Start of day

```bash
# Start minikube
minikube start

# Start tunnel in a separate terminal (Mac only; required for ingress access)
sudo minikube tunnel

# Verify
kubectl get pods -n auth-service
curl -k https://auth.local/actuator/health
```

### Iteration

For code changes:

```bash
# Edit Java code, commit, push
# CI builds, CD pushes new image to ECR

# Pick up new image in minikube
kubectl rollout restart deployment/auth-service -n auth-service
```

For manifest changes:

```bash
# Edit YAML in k8s/
kubectl apply -k k8s/overlays/dev/auth-service
```

### End of day

```bash
# Ctrl+C the tunnel terminal
minikube stop
```

See [docs/NETWORKING-README.md](./docs/NETWORKING-README.md) for the full daily workflow including troubleshooting.

---

## Environments

| Environment           | Where it runs                                | Image source                       | TLS source           | Database               |
| --------------------- | -------------------------------------------- | ---------------------------------- | -------------------- | ---------------------- |
| **Local Spring Boot** | Your laptop, direct `mvn spring-boot:run`    | N/A                                | None                 | Local Postgres         |
| **Dev (minikube)**    | Your laptop, Kubernetes                      | ECR Public, manual `kubectl apply` | Self-signed (manual) | In-cluster StatefulSet |
| **Dev (EKS)**         | AWS, automated deploy                        | ECR Public/Private, CD pipeline    | ACM                  | RDS (TBD)              |
| **Staging (EKS)**     | AWS, automated deploy with manual trigger    | ECR Public/Private, CD pipeline    | ACM                  | RDS (TBD)              |
| **Prod (EKS)**        | AWS, automated deploy with reviewer approval | ECR Public/Private, CD pipeline    | ACM                  | RDS (TBD)              |

See [docs/CI-CD-ARCHITECTURE-README.md](./docs/CI-CD-ARCHITECTURE-README.md) for the full promotion model.

---

## Adding a New Microservice

Brief outline (see [docs/CI-CD-ARCHITECTURE-README.md § Adding a New Microservice](./docs/CI-CD-ARCHITECTURE-README.md#adding-a-new-microservice) for details):

```bash
# 1. Create service directory mirroring auth-service/
# 2. Copy and adapt CI/CD workflow callers
cp .github/workflows/ci-auth-service.yml .github/workflows/ci-NEW-service.yml
cp .github/workflows/cd-auth-service.yml .github/workflows/cd-NEW-service.yml

# 3. Copy Kustomize base and overlays
cp -r k8s/base/auth-service k8s/base/NEW-service
cp -r k8s/overlays/dev/auth-service k8s/overlays/dev/NEW-service

# 4. Update service-name in all copied files (sed -i)
# 5. Create ECR Public repo
# 6. Add to Dependabot config
# 7. Add to nightly security scan matrix
```

---

## Security

### What's protected

- **Dependency CVEs**: Dependabot continuous + nightly OWASP scan
- **Code-level vulnerabilities**: CodeQL on every PR
- **Static analysis**: Semgrep with OWASP and Spring-specific rules
- **Image vulnerabilities**: Trivy scan post-push to ECR
- **Branch protection**: PRs require CI green + reviewer approval to merge

### What's NOT in version control

The following are gitignored:

- `k8s/overlays/*/auth-service/postgres.env` — real DB credentials
- `k8s/overlays/*/auth-service/auth.env` — JWT signing key

For production, secrets come from **AWS Secrets Manager** via the Secrets Store CSI driver. See [docs/CI-CD-ARCHITECTURE-README.md § Secrets Management](./docs/CI-CD-ARCHITECTURE-README.md#secrets-management).

### TLS certificates

For dev: self-signed certs created via openssl, stored in Kubernetes Secret.
For prod: AWS ACM (with ALB) or Let's Encrypt (with cert-manager).

See [docs/CERTIFICATE-TLS-README.md](./docs/CERTIFICATE-TLS-README.md) for the full lifecycle.

---

## Troubleshooting

The fastest path:

1. Check what's broken: `kubectl get pods -n auth-service`
2. Get details: `kubectl describe pod <name> -n auth-service`
3. Read logs: `kubectl logs <name> -n auth-service` (add `--previous` for crashed containers)

For specific symptoms:

- **Connection errors / can't reach auth.local** → [docs/NETWORKING-README.md § Troubleshooting by Symptom](./docs/NETWORKING-README.md#troubleshooting-by-symptom)
- **Certificate warnings / TLS errors** → [docs/CERTIFICATE-TLS-README.md § Common Issues](./docs/CERTIFICATE-TLS-README.md#common-issues-and-their-causes)
- **CI/CD pipeline failures** → Workflow logs in GitHub Actions UI
- **Pod crash on startup** → `kubectl logs <pod> --previous` (most common: secrets misconfigured, DB unreachable)

---

## Migration to AWS EKS

The Kustomize manifests are designed to migrate cleanly. Most changes are env-specific overlays, not base manifests.

What changes:

- Image registry: ECR Public → ECR Private (optional)
- Ingress: NGINX → AWS Load Balancer Controller (ALB)
- TLS: Self-signed Secret → ACM ARN annotation
- Database: In-cluster StatefulSet → RDS
- Secrets: Manual + env files → AWS Secrets Manager via CSI driver
- Storage: hostpath → EBS via CSI driver

What stays the same:

- Deployment manifests (just image tag updates)
- Service manifests
- HPA configuration
- Application code

See [docs/CI-CD-ARCHITECTURE-README.md § AWS Migration Guide](./docs/CI-CD-ARCHITECTURE-README.md#aws-migration-guide-minikube--eks) for the full plan.

---

## Contributing

This is a personal reference project. PRs welcome for educational improvements.

Before opening a PR:

- Run tests locally: `cd auth-service && ./mvnw verify`
- Verify Kustomize builds: `kubectl kustomize k8s/overlays/dev/auth-service`
- Check for new dependencies that need overrides in `pom.xml`

---

## License

[Add your license here — MIT, Apache 2.0, etc.]
