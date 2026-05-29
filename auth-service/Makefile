.PHONY: dep-updates-all dep-updates dep-tree dep-check build run test clean docker-build docker-run docker-stop logs help

# ── Variables ────────────────────────────────────────────────────────────────
APP_NAME=auth-service
IMAGE_NAME=anpks/$(APP_NAME)
IMAGE_TAG=latest
PORT=8081

# ── Maven ─────────────────────────────────────────────────────────────────────

# Full update report — what's available for both declared and managed deps.
# This is verbose; pipe through `less` or grep for what you care about.
dep-updates-all:
	mvn versions:display-dependency-updates --no-transfer-progress -B

# Property-managed dependencies — shows what newer versions are available
# for any <foo.version> property in pom.xml.
dep-updates:
	mvn versions:display-property-updates --no-transfer-progress -B

# Full tree (all dependencies) — pipe through `less` if it's large
dep-tree:
	mvn dependency:tree --no-transfer-progress -B

# Tree filtered to a specific library. Usage:
#   make dep-check LIB=org.apache.tomcat.embed:tomcat-embed-core
#   make dep-check LIB=org.postgresql:postgresql
#   make dep-check LIB=io.jsonwebtoken:jjwt-api
dep-check:
	@if [ -z "$(LIB)" ]; then \
		echo "Usage: make dep-check LIB=<groupId>:<artifactId>"; \
		echo "Example: make dep-check LIB=org.apache.tomcat.embed:tomcat-embed-core"; \
		exit 1; \
	fi
	mvn dependency:tree -Dincludes=$(LIB) --no-transfer-progress -B
 

# ── Build ─────────────────────────────────────────────────────────────────────
build:
	mvn clean install -DskipTests

build-full:
	mvn clean install

# ── Run ───────────────────────────────────────────────────────────────────────
run:
	mvn spring-boot:run

# ── Test ──────────────────────────────────────────────────────────────────────
test:
	mvn test

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	mvn clean

# ── Docker ───────────────────────────────────────────────────────────────────
docker-build: build
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-run:
	docker run -d \
		--name $(APP_NAME) \
		-p $(PORT):$(PORT) \
		--env-file .env \
		$(IMAGE_NAME):$(IMAGE_TAG)

docker-stop:
	docker stop $(APP_NAME) && docker rm $(APP_NAME)

docker-logs:
	docker logs -f $(APP_NAME)

# ── DB ────────────────────────────────────────────────────────────────────────
db-setup:
	../scripts/setup_db.sh

db-migrate:
	mvn flyway:migrate

db-info:
	mvn flyway:info

db-validate:
	mvn flyway:validate

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "  build          					Build jar skipping tests"
	@echo "  build-full     					Build jar with tests"
	@echo "  run            					Run app locally with Maven"
	@echo "  test           					Run tests"
	@echo "  clean          					Clean target directory"
	@echo "  docker-build   					Build Docker image"
	@echo "  docker-run     					Run Docker container"
	@echo "  docker-stop    					Stop and remove container"
	@echo "  docker-logs    					Tail container logs"
	@echo "  db-setup       					Run database setup script"
	@echo "  db-migrate     					Run Flyway migrations"
	@echo "  db-info        					Show Flyway migration status"
	@echo "  db-validate    					Validate Flyway migrations"
	@echo "  dep-tree       					full dependency tree"
	@echo "  dep-check LIB=<group>:<artifact>   filter tree to one library"
	@echo "  dep-updates                        newer versions of pinned properties"
	@echo "  dep-updates-all                    newer versions of all dependencies"
	@echo ""
