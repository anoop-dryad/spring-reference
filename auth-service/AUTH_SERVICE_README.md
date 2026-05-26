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

---

## Prerequisites

- Java 21 (via [sdkman](https://sdkman.io/): `sdk install java 21.0.11-amzn`)
- Maven 3.9+
- PostgreSQL 16+
- Docker Desktop
- [direnv](https://direnv.net/) (`brew install direnv`)

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
- Runs as a non-root system user for security
- Uses `/dev/urandom` entropy source to prevent startup hangs
- Healthcheck via `/actuator/health`

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
