.PHONY: build run test clean docker-build docker-run docker-stop logs help

# ── Variables ────────────────────────────────────────────────────────────────
APP_NAME=auth-service
IMAGE_NAME=anpks/$(APP_NAME)
IMAGE_TAG=latest
PORT=8081

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
	@echo "  build          Build jar skipping tests"
	@echo "  build-full     Build jar with tests"
	@echo "  run            Run app locally with Maven"
	@echo "  test           Run tests"
	@echo "  clean          Clean target directory"
	@echo "  docker-build   Build Docker image"
	@echo "  docker-run     Run Docker container"
	@echo "  docker-stop    Stop and remove container"
	@echo "  docker-logs    Tail container logs"
	@echo "  db-setup       Run database setup script"
	@echo "  db-migrate     Run Flyway migrations"
	@echo "  db-info        Show Flyway migration status"
	@echo "  db-validate    Validate Flyway migrations"
	@echo ""
