# Database Setup

This guide covers the one-time PostgreSQL setup required before running the service.
The setup script creates the database, schema, and two least-privilege users:
one for Flyway migrations and one for the application runtime.

---

## Prerequisites

- PostgreSQL installed and running
- `psql` available in your terminal
- [`direnv`](https://direnv.net/) installed for environment variable management

### Install direnv

```bash
# macOS
brew install direnv

# Ubuntu/Debian
sudo apt install direnv
```

Add to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
eval "$(direnv hook zsh)"   # zsh
eval "$(direnv hook bash)"  # bash
```

---

## Setup Steps

### 1. Configure environment variables

Add `.envrc` with your values:

```bash
# Database
export PGHOST=localhost
export PGPORT=5432
export DB_NAME=spring_ref_db
export DB_SCHEMA=auth

# Flyway migration user (DDL privileges)
export DB_FLYWAY_USER=flyuser
export DB_FLYWAY_PASSWORD=your_strong_password

# App runtime user (DML only)
export DB_APP_USER=appuser
export DB_APP_PASSWORD=your_strong_password

# PostgreSQL superuser for running the setup script
export PGUSER=postgres
```

Allow direnv to load the file:

```bash
direnv allow
```

Verify variables are loaded:

```bash
echo $DB_NAME        # should print your db name
echo $DB_APP_USER    # should print appuser
```

---

### 2. Run the setup script

```bash
chmod +x setup_db.sh
./setup_db.sh
```

The script will:

- Create the database
- Create the `flyuser` and `appuser` roles
- Create the schema
- Apply least-privilege access controls
- Print a verification summary

---

### 3. Verify the setup

Connect to the database:

```bash
psql -U postgres -d spring_ref_db
```

Check schemas:

```sql
\dn+
```

Expected output:

```
  Name  | Owner   | Access privileges
--------+---------+-----------------------------
 auth   | flyuser | flyuser=UC/flyuser, appuser=U/flyuser
 public | ...     | ...
```

Check users:

```sql
\du
```

---

### 4. Run the application

Once the database is set up, start the application. Flyway will automatically
run any pending migration scripts from `src/main/resources/db/migration/` on startup.

Make sure the environment variables are loaded in your run environment:

**IntelliJ:** `Run → Edit Configurations → Environment Variables` and add:

```
DB_NAME=spring_ref_db
DB_SCHEMA=auth
DB_APP_USER=appuser
DB_APP_PASSWORD=your_password
DB_FLYWAY_USER=flyuser
DB_FLYWAY_PASSWORD=your_password
DB_HOST=localhost
DB_PORT=5432
```

**Terminal:**

```bash
direnv allow   # if not already done
mvn spring-boot:run
```

---

## User Privileges Summary

| Privilege                | flyuser | appuser   |
| ------------------------ | ------- | --------- |
| Connect to DB            | ✅      | ✅        |
| Create/drop schema       | ✅      | ❌        |
| Create/alter/drop tables | ✅      | ❌        |
| SELECT                   | ✅      | ✅        |
| INSERT / UPDATE / DELETE | ✅      | ✅        |
| TRUNCATE / DROP          | ✅      | ❌        |
| Sequences                | ✅      | READ only |

---

## File Reference

| File                 | Purpose                                     | Commit? |
| -------------------- | ------------------------------------------- | ------- |
| `postgres_setup.sql` | SQL script — creates DB, users, privileges  | ✅ Yes  |
| `setup_db.sh`        | Shell wrapper — reads `.envrc` and runs SQL | ✅ Yes  |
| `.envrc`             | Your actual credentials                     | ❌ No   |

---

## Teardown (reset local DB)

To drop everything and start fresh:

```sql
-- connect as superuser
psql -U postgres

-- drop database
DROP DATABASE spring_ref_db;

-- drop users
DROP USER flyuser;
DROP USER appuser;
```

Then re-run `./setup_db.sh` to recreate everything.

---

## Troubleshooting

**`direnv: error .envrc is blocked`**

```bash
direnv allow
```

**`FATAL: role "${DB_APP_USER}" does not exist`**
Environment variables are not loaded. Run `direnv allow` or export them manually.

**`permission denied for schema auth`**
The database user doesn't have the right privileges. Re-run `setup_db.sh` or
manually grant privileges — see `postgres_setup.sql` sections 5–7.

**`FATAL: database does not exist`**
The setup script hasn't been run yet, or the DB was dropped. Run `./setup_db.sh`.
