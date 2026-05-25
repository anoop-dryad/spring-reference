FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# Creates a dedicated system user to run the app instead of running as root
RUN addgroup -S anpks && adduser -S -G anpks anpks

COPY target/*.jar app.jar

# switches to that user before running the app.
USER anpks
EXPOSE 8081

# Healthcheck via actuator
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD curl -f http://localhost:8081/actuator/health || exit 1

# Tells the JVM to use /dev/urandom instead of /dev/random as the entropy source for cryptographic operations (like JWT signing, SSL handshakes).

# /dev/random — blocks until enough entropy is collected from the OS. In a container with little hardware activity this can cause your app to hang for seconds on startup or during crypto operations
# /dev/urandom — non-blocking, uses a CSPRNG seeded from the OS entropy pool — still cryptographically secure, never blocks

# The /./ in the path is a historical trick to force the JVM to use the non-blocking version — some older JVM versions would map /dev/urandom back to /dev/random without it.
# In short — without this flag your containerized Spring Boot app can hang noticeably on startup or during JWT token generation.
ENTRYPOINT ["java",  "-Djava.security.egd=file:/dev/./urandom","-jar", "app.jar"]

