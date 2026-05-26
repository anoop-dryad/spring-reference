# services/auth-service/Dockerfile
#
# Multi-stage build for Spring Boot on Java 21
#
# Stage 1 (builder): Maven build — produces fat JAR
# Stage 2 (layers):  Spring Boot layer extraction — for optimal Docker layer caching
# Stage 3 (runtime): Minimal JRE image — no build tools, no shell in PID 1


# ── Stage 1: Build ────────────────────────────────────────────────────────────
# Use an image that actually has Maven. eclipse-temurin:*-jdk has no mvn.
FROM maven:3.9-eclipse-temurin-21 AS builder

WORKDIR /build

# Copy pom.xml first so the dependency layer is cached until pom.xml changes.
# Source code changes won't trigger a re-download of dependencies.
COPY pom.xml .
RUN mvn dependency:go-offline -B --no-transfer-progress

# Copy source and build. Tests should run in CI, not in the image build.
COPY checkstyle.xml .
COPY src ./src
RUN mvn package -DskipTests --no-transfer-progress -B \
    && mv target/*.jar target/app.jar

# ── Stage 2: Layer extraction ─────────────────────────────────────────────────
# Use the JRE here — we only need `java` to run layertools.
FROM eclipse-temurin:21-jre-alpine AS layers

WORKDIR /build
COPY --from=builder /build/target/app.jar app.jar
# Spring Boot ships a tool called layertools that splits the fat JAR 
# back into separate directories based on how often things change:
RUN java -Djarmode=layertools -jar app.jar extract
# after running the above command, we get 4 directories instead of one jar
#   /build/
#       ├── dependencies/              ← ~45MB — third-party libs (changes rarely)
#       ├── spring-boot-loader/        ← ~500KB — Spring Boot framework (changes only on Spring upgrade)
#       ├── snapshot-dependencies/     ← ~2MB — SNAPSHOT deps (changes occasionally)
#       └── application/               ← ~100KB — YOUR code (changes every commit)
# These aren't just folders — they're sorted by change frequency, least-changing first.

# ── Stage 3: Runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-alpine AS runtime

# wget ships with BusyBox in Alpine — no need to install curl just for healthchecks.
# If you must have curl (e.g. for sidecar debugging), uncomment:
# RUN apk add --no-cache curl

# Create non-root user with explicit UID/GID. Fixed IDs help with:
#   - Kubernetes PodSecurity policies (runAsUser: 10001)
#   - Volume permissions (EFS, EBS) on AWS
#   - Reproducible image scans
RUN addgroup -S -g 10001 appgroup \
    && adduser  -S -u 10001 -G appgroup appuser

WORKDIR /app

# Copy layers in order from least-to-most frequently changed.
# Use --chown so the running user actually owns its files.
COPY --from=layers --chown=appuser:appgroup /build/dependencies/          ./
COPY --from=layers --chown=appuser:appgroup /build/spring-boot-loader/    ./
COPY --from=layers --chown=appuser:appgroup /build/snapshot-dependencies/ ./
COPY --from=layers --chown=appuser:appgroup /build/application/           ./

USER appuser

EXPOSE 8080

# JVM tuning for containers. Notes:
#   -XX:+UseContainerSupport          on by default in Java 21; kept explicit for clarity
#   -XX:MaxRAMPercentage=75.0         heap = 75% of container memory limit
#   -XX:InitialRAMPercentage=50.0     start with a sensible heap, fewer resize pauses
#   -XX:+UseG1GC                      good default for Spring Boot
#                                     (consider ZGC if you have >4GB heap and need low pause)
#   -XX:+HeapDumpOnOutOfMemoryError   capture heap for post-mortem
#   -XX:HeapDumpPath=/tmp/...         /tmp is writable; mount an emptyDir if you want to keep dumps
#   -XX:+ExitOnOutOfMemoryError       fail fast on OOM so k8s restarts the pod cleanly
#   -Djava.security.egd=...           non-blocking entropy (faster startup, JWT signing, TLS)
ENV JAVA_OPTS="-XX:+UseContainerSupport \
    -XX:MaxRAMPercentage=75.0 \
    -XX:InitialRAMPercentage=50.0 \
    -XX:+UseG1GC \
    -XX:+HeapDumpOnOutOfMemoryError \
    -XX:HeapDumpPath=/tmp/heapdump.hprof \
    -XX:+ExitOnOutOfMemoryError \
    -Djava.security.egd=file:/dev/./urandom"

# IMPORTANT: `exec` makes the JVM PID 1 so it receives SIGTERM directly.
# Without exec, sh stays as PID 1 and the JVM never gets the shutdown signal —
# Kubernetes then SIGKILLs your pod after the grace period (default 30s),
# breaking in-flight requests and clean DB connection close.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]

# No HEALTHCHECK directive — Kubernetes liveness/readiness probes handle this.
# Use Spring Boot Actuator endpoints in your Deployment manifest:
#   livenessProbe:  /actuator/health/liveness
#   readinessProbe: /actuator/health/readiness
