# Logging Reference

> **Purpose**: How log aggregation works in this deployment, why each piece exists, and how to query effectively. Read this when you need to debug an issue across pods, add log-based alerts, or understand the log pipeline from app to Grafana.

---

## Table of Contents

1. [Logging in 60 Seconds](#logging-in-60-seconds)
2. [Why Aggregate Logs at All](#why-aggregate-logs-at-all)
3. [The Architecture](#the-architecture)
4. [Loki vs. Other Log Stacks](#loki-vs-other-log-stacks)
5. [The Log Journey — Pod to Grafana](#the-log-journey--pod-to-grafana)
6. [Setup — Installing Loki and Promtail](#setup--installing-loki-and-promtail)
7. [Structured Logging in Spring Boot](#structured-logging-in-spring-boot)
8. [The Two-Layer JSON Problem](#the-two-layer-json-problem)
9. [LogQL Crash Course](#logql-crash-course)
10. [Useful Queries](#useful-queries)
11. [Log Levels — What to Log and When](#log-levels--what-to-log-and-when)
12. [Adding Custom Context to Logs](#adding-custom-context-to-logs)
13. [Correlating Logs With Metrics](#correlating-logs-with-metrics)
14. [Production Considerations](#production-considerations)
15. [Troubleshooting](#troubleshooting)

---

## Logging in 60 Seconds

Logs are text records of what your application did. In a single-server world, you'd `tail -f /var/log/myapp.log`. In Kubernetes:

- Pods are ephemeral — restart = logs gone
- Multiple replicas — logs split across pods
- Multiple services — logs split across applications
- Multiple namespaces — logs split across environments

You can't grep across all of this with `kubectl logs`. You need centralized log aggregation: every pod ships its logs to one searchable place.

This setup uses **Loki** (the log database) + **Promtail** (the shipper) + **Grafana** (the UI). Same UI as your metrics — one tool for everything.

---

## Why Aggregate Logs at All

Concrete scenarios that motivate this:

**A user reports an error** — they tell you "I got a 500 around 2:15 PM." Without aggregation: which pod handled it? You'd `kubectl logs` each replica, hoping you catch the right time window. With aggregation: query the time range across all pods in seconds.

**A pod crashed last night** — without aggregation, the logs vanished with the pod. With aggregation, they were shipped to Loki before the crash. You can investigate post-mortem.

**You need to find all errors from one user** — search across all your services for a specific user ID. Impossible with `kubectl logs`; trivial with LogQL.

**You want to alert on log patterns** — "fire an alert if more than 5 errors per minute appear in any auth service log." Requires logs in a queryable system.

**Compliance / audit** — many regulations require retaining logs for 90 days or more. Pod logs don't satisfy this; aggregation does.

---

## The Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Kubernetes cluster                                                │
│                                                                   │
│  ┌──────────────────────┐                                        │
│  │  auth-service pod    │  app writes to stdout                  │
│  │   (your code)        │                                        │
│  └──────────┬───────────┘                                        │
│             │                                                     │
│             ▼ (Kubernetes captures stdout)                       │
│  /var/log/pods/auth-service_*/auth-service/0.log                 │
│             │                                                     │
│             ▼                                                     │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Promtail (DaemonSet — runs on every node)                │   │
│  │ - Tails /var/log/pods/                                   │   │
│  │ - Adds K8s metadata as labels (namespace, pod, ...)      │   │
│  │ - Batches and ships every few seconds                    │   │
│  └──────────────┬───────────────────────────────────────────┘   │
│                 │                                                 │
│                 ▼                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Loki (StatefulSet)                                       │   │
│  │ - Stores logs on persistent disk                         │   │
│  │ - Indexes by labels (NOT full text)                      │   │
│  │ - Exposes HTTP API                                       │   │
│  └──────────────┬───────────────────────────────────────────┘   │
│                 │                                                 │
│                 ▼                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Grafana                                                  │   │
│  │ - Loki added as data source                              │   │
│  │ - "Explore" tab for ad-hoc queries                       │   │
│  │ - Dashboards can show metrics + logs together            │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

Components:

- **Your app** — writes logs to stdout (Spring Boot default; do NOT write to files inside containers)
- **Container runtime** — Kubernetes captures stdout and saves it to disk on the node
- **Promtail** — a DaemonSet (one pod per node) that tails those log files
- **Loki** — stores logs efficiently, indexed by labels
- **Grafana** — your UI for everything

---

## Loki vs. Other Log Stacks

| Stack | Storage | Indexing | Memory | Best for |
|---|---|---|---|---|
| **Loki** | Object storage (or disk) | Labels only — cheap | ~500 MB | K8s, low cost, simple queries |
| **ELK (Elasticsearch + Kibana)** | Elasticsearch | Full-text indexing | 2+ GB | Heavy search workloads |
| **Splunk** | Proprietary | Full-text | Heavy | Enterprises with budget |
| **CloudWatch Logs** | AWS managed | Full-text | None (managed) | AWS-only, pay per GB |
| **Datadog** | SaaS | Full-text | None (managed) | Polished UI, expensive |

**Why Loki for this project**: same Grafana UI you're already using for metrics, low memory footprint (fits in minikube), open source, scales to large clusters when needed. The cost of "labels only" indexing is that you can't do free-text search efficiently — but in practice you filter by labels first (namespace, pod, level) then substring-search the remaining lines, which is usually fast.

---

## The Log Journey — Pod to Grafana

Understanding each hop helps debug "why aren't my logs showing up?"

### Step 1: App Writes to Stdout

Spring Boot writes to stdout by default. Don't change this. Pods running in K8s should NEVER write logs to files — the files vanish when the pod is rescheduled.

If your code uses `System.out.println` or any Logback configuration that targets `ConsoleAppender`, you're already doing this right.

### Step 2: Container Runtime Captures Stdout

Kubernetes captures stdout and writes it to a file on the host node:

```
/var/log/pods/<namespace>_<pod>/auth-service/0.log
```

The runtime wraps each log line in JSON:

```json
{"log":"<your actual log line>\n","stream":"stdout","time":"2026-06-04T19:37:49Z"}
```

You can't disable this wrapping — it's how the container runtime stores logs. This becomes the "two-layer JSON" issue we'll cover later.

### Step 3: Promtail Reads and Ships

Promtail runs as a DaemonSet — one pod on every K8s node. Each Promtail pod:

1. Mounts `/var/log/pods/` from the host
2. Tails new log files
3. Reads pod metadata from the K8s API
4. Adds labels: `namespace`, `pod`, `container`, `app`, `node_name`, etc.
5. Batches log lines and pushes them to Loki via HTTP

The labels added by Promtail come from K8s metadata. You can see them via:

```bash
k get pods -n auth-service --show-labels
```

These exact labels appear in Loki.

### Step 4: Loki Stores and Indexes

Loki receives log lines and stores them. The key design decision: **only labels are indexed, not log content**.

```
Index:    {namespace="auth-service", pod="auth-service-x"}
          ↓
Storage:  block of compressed log lines (text)
```

When you query, Loki finds the relevant log blocks by label, then linearly scans the text for substring matches. This is why label-based queries are fast and full-text scans are slower.

### Step 5: Grafana Queries Loki

Grafana sends LogQL queries to Loki's HTTP API. Loki returns matching log lines. Grafana displays them, optionally parsed.

This whole chain takes ~5-10 seconds from log line to visible in Grafana — Promtail batches, network hops, Loki ingests. Don't expect instant logs.

---

## Setup — Installing Loki and Promtail

### Prerequisites

You should already have:
- minikube running
- `kube-prometheus-stack` installed in `monitoring` namespace
- Grafana accessible via port-forward

### Install via Helm

The deprecated `grafana/loki-stack` chart bundles Loki + Promtail in one install. Use it for now (the new pattern is two separate charts — migrate when convenient):

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=2Gi \
  --set loki.resources.requests.memory=200Mi \
  --set loki.resources.limits.memory=500Mi \
  --set promtail.resources.requests.memory=50Mi \
  --set promtail.resources.limits.memory=150Mi
```

Flag breakdown:

- `--namespace monitoring` — co-located with Prometheus + Grafana
- `grafana.enabled=false` / `prometheus.enabled=false` — already installed via kube-prometheus-stack
- `loki.persistence.enabled=true` — survives pod restarts (2 GB PVC)
- Memory limits — sized for minikube; bump in production

### Verify

```bash
k get pods -n monitoring | grep -E "loki|promtail"
```

Expected:
```
loki-0                          1/1   Running   0   1m
loki-promtail-<hash>            1/1   Running   0   1m
```

If pods aren't ready in 3 minutes:

```bash
k describe pod -n monitoring loki-0 | grep -A 10 "Events"
k logs -n monitoring loki-0 --tail=30
```

Common issue: PVC not binding (storage class problem).

### Add Loki as a Grafana Data Source

Loki and Grafana don't auto-connect. You add the data source via UI:

1. Port-forward Grafana: `k port-forward -n monitoring svc/monitoring-grafana 3000:80`
2. Open `http://localhost:3000`
3. Sidebar → **Connections → Data sources**
4. Click **+ Add new data source**, choose **Loki**
5. URL: `http://loki:3100`
6. Click **Save & test**

You may see "Unable to connect to Loki" even when it works — try the **Explore** tab with a query first. If the query succeeds, the data source works regardless of the test result.

---

## Structured Logging in Spring Boot

By default, Spring Boot emits plain text logs:

```
2026-06-04T19:37:49.903Z INFO 1 --- [auth-service] [main] com.zaxxer.hikari.HikariDataSource : HikariPool-1 - Starting...
```

Queryable by substring (`|= "ERROR"`), but you can't query by structured fields. Switching to JSON makes logs much more powerful.

### Spring Boot 3.4+ Native Support

Spring Boot 3.4 added native structured logging. One config block:

```yaml
# auth-service/src/main/resources/application.yaml
# AND k8s/base/auth-service/configmap.yml (mirror the change)

spring:
  application:
    name: auth-service

logging:
  structured:
    format:
      console: ecs
    ecs:
      service:
        name: auth-service
        environment: ${SPRING_PROFILES_ACTIVE:dev}

  level:
    "[com.anpks]": "${LOG_LEVEL:INFO}"
```

The `format: ecs` tells Spring Boot to emit ECS (Elastic Common Schema) format JSON.

After rebuild and redeploy, logs look like:

```json
{"@timestamp":"2026-06-04T19:37:49.903Z","log.level":"INFO","process.thread.name":"main","log.logger":"com.zaxxer.hikari.HikariDataSource","message":"HikariPool-1 - Starting...","ecs.version":"8.11","service.name":"auth-service","service.environment":"dev"}
```

Each log line is a parseable JSON object with named fields.

### What Is ECS?

ECS = Elastic Common Schema. A standardized field naming convention from Elastic, widely adopted by other tools (Datadog, AWS, Splunk).

ECS gives you predictable field names:

- `@timestamp` — when the log was created
- `log.level` — INFO, WARN, ERROR, DEBUG
- `log.logger` — Java logger name (typically class)
- `message` — the log message
- `service.name` — application name
- `service.environment` — dev/staging/prod
- `process.thread.name` — thread name
- `ecs.version` — schema version

Using ECS means anything that understands the schema (Loki, CloudWatch, Datadog, Elastic) gives you consistent field names.

### Alternative Formats

Spring Boot also supports:

- `format: logstash` — Logstash JSON encoder format (older, used by ELK)
- `format: gelf` — Graylog format

For new projects, **use ECS**. It's the most widely supported.

### What If You're Below Spring Boot 3.4

If you're on 3.3 or earlier, native structured logging isn't available. Use the Logstash Logback Encoder:

```xml
<!-- pom.xml -->
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>7.4</version>
</dependency>
```

```xml
<!-- src/main/resources/logback-spring.xml -->
<configuration>
    <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LogstashEncoder">
            <customFields>{"service.name":"auth-service","service.environment":"dev"}</customFields>
        </encoder>
    </appender>
    
    <root level="INFO">
        <appender-ref ref="JSON"/>
    </root>
</configuration>
```

Same conceptual result, more configuration. Upgrade to Spring Boot 3.4+ when you can — much simpler.

---

## The Two-Layer JSON Problem

This trips up everyone who switches to JSON logging in Kubernetes.

### What Actually Happens

Your app emits JSON to stdout:

```json
{"@timestamp":"2026-06-04T19:37:49Z","log.level":"INFO","message":"Started"}
```

The container runtime captures this and wraps it in ANOTHER JSON envelope:

```json
{"log":"{\"@timestamp\":\"2026-06-04T19:37:49Z\",\"log.level\":\"INFO\",\"message\":\"Started\"}\n","stream":"stdout","time":"..."}
```

So Loki receives **JSON-inside-JSON**. The outer wrapper is from K8s; the inner is from your app.

This means a query like `| json | level="ERROR"` doesn't work directly — `level` is buried in the inner JSON, not the outer.

### The Solution: Parse Both Layers

```logql
{namespace="auth-service"} 
  | json                       # parse the OUTER wrapper, extract "log" field
  | line_format "{{.log}}"     # replace the line with the value of "log"
  | json                       # parse the INNER JSON (your actual ECS log)
  | __error__=""               # discard lines where parsing failed
```

After this pipeline, Loki has the ECS fields available. You can then filter:

```logql
{namespace="auth-service"} 
  | json 
  | line_format "{{.log}}" 
  | json 
  | __error__="" 
  | level="ERROR"
```

### Why `| __error__=""`

When Loki parses JSON and encounters a non-JSON line (e.g., a stack trace fragment, or the very first init line before logging is configured), it adds an `__error__` label to that line. Filtering with `__error__=""` keeps only successfully-parsed lines.

Without this, your queries may break when a non-JSON line shows up.

### Save Your Standard Query Prefix

Most LogQL queries against your services will start with this exact prefix:

```logql
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__=""
```

Get used to typing it. It's the "I want to query the actual app logs, not the K8s wrapper" pattern.

---

## LogQL Crash Course

LogQL is Loki's query language. Designed to feel like PromQL.

### Anatomy of a Query

```
{label="value"} | parser | filter | line_format ...
   stream selector  |  pipeline stages
```

- **Stream selector** (required): which logs to read, by label
- **Pipeline stages** (optional): parse, filter, format

### Stream Selectors

```logql
# All logs from auth-service namespace
{namespace="auth-service"}

# Multiple labels
{namespace="auth-service", container="auth-service"}

# Regex match on label value
{pod=~"auth-service-.+"}

# Negation
{namespace="auth-service", container!="postgres"}
```

Stream selectors are fast — they use Loki's index.

### Line Filters

After selecting streams, filter the lines themselves:

```logql
# Lines containing "ERROR"
{namespace="auth-service"} |= "ERROR"

# Lines NOT containing "health"
{namespace="auth-service"} != "actuator/health"

# Regex
{namespace="auth-service"} |~ "ERROR|WARN"

# Regex negation
{namespace="auth-service"} !~ "health|info"
```

Operators:
- `|=` contains
- `!=` does not contain
- `|~` regex
- `!~` regex not match

These do linear text scans — fast for narrow time ranges, slow for wide ones.

### Parsing Stages

Parse log content into structured fields:

```logql
# Parse JSON — adds all JSON fields as queryable labels
{namespace="auth-service"} | json

# Parse logfmt (key=value pairs)
{namespace="auth-service"} | logfmt

# Parse with regex (named groups become fields)
{namespace="auth-service"} | regexp "(?P<level>\\w+) (?P<msg>.+)"
```

### Label Filters After Parsing

Once you've parsed, you can filter by extracted fields:

```logql
{namespace="auth-service"} | json | level="ERROR"

# Numeric comparisons
{namespace="auth-service"} | json | duration > 1000

# String regex
{namespace="auth-service"} | json | logger=~"com.anpks.*"
```

### Line Formatting

Change how each log line is displayed:

```logql
# Show only the message field
{namespace="auth-service"} | json | line_format "{{.message}}"

# Custom format
{namespace="auth-service"} 
  | json 
  | line_format "[{{.\"log.level\"}}] {{.\"log.logger\"}}: {{.message}}"
```

Note: ECS field names have dots, which need escaping with backslash in `line_format`.

### Aggregations (Like PromQL)

Count logs per time bucket:

```logql
# How many ERROR logs per minute?
sum(count_over_time({namespace="auth-service"} | json | level="ERROR" [1m]))

# By level
sum by (level) (count_over_time({namespace="auth-service"} | json [5m]))
```

This produces numeric time-series, queryable in Grafana panels just like Prometheus metrics.

---

## Useful Queries

Reference queries for common needs. Replace the prefix with your namespace.

### Basic

```logql
# All logs from auth-service
{namespace="auth-service"}

# Just one container
{namespace="auth-service", container="auth-service"}

# Just one pod
{pod="auth-service-894fdfb5f-blxvv"}
```

### With Structured JSON Parsing

```logql
# The "show me real app logs" prefix
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__=""

# All errors
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | level="ERROR"

# All warnings
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | level="WARN"

# Specific logger
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | logger=~"com.anpks.*"
```

### Counting and Aggregating

```logql
# Error rate per minute
sum(count_over_time({namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | level="ERROR" [1m]))

# All log levels, counted by level
sum by (level) (count_over_time({namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" [5m]))

# Logs per pod (useful for spotting noisy pods)
sum by (pod) (rate({namespace="auth-service"}[1m]))
```

### Debugging

```logql
# Find logs around a specific time (set Grafana time range to the period)
{namespace="auth-service"} |= "exception"

# Stack traces (multi-line — they appear as one log entry per line)
{namespace="auth-service"} |= "at com.anpks"

# Database connection issues
{namespace="auth-service"} |~ "connection|HikariCP|postgres"
```

### Cross-Service Searches

```logql
# Errors across ALL services
{namespace=~".+"} | json | line_format "{{.log}}" | json | __error__="" | level="ERROR"

# Logs from your custom code only (filters out Spring framework noise)
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | logger=~"com.anpks.*"
```

---

## Log Levels — What to Log and When

Spring Boot supports five levels (DEBUG, INFO, WARN, ERROR, FATAL — though FATAL is rare). Understanding what each is for matters because you'll query by level.

| Level | When to use | Example |
|---|---|---|
| **DEBUG** | Internal state for diagnosing bugs | "Cache hit for key user_123" |
| **INFO** | Normal business events worth recording | "User logged in: user_id=123" |
| **WARN** | Unexpected but recoverable | "Rate limit approaching for IP X" |
| **ERROR** | Something failed — needs attention | "Database query failed: timeout" |

### Setting Levels Per Package

In application.yaml:

```yaml
logging:
  level:
    root: INFO                              # default
    "[com.anpks]": DEBUG                    # your code more verbose
    "[com.anpks.auth.security]": INFO       # security less verbose
    "[org.hibernate.SQL]": DEBUG            # show SQL queries
    "[org.springframework.web]": WARN       # Spring web less noisy
```

You can be very granular with package paths.

### Dynamic Level Changes (No Restart Needed)

Spring Boot Actuator exposes a loggers endpoint:

```bash
# Get current level for a logger
curl -k https://auth.local/actuator/loggers/com.anpks

# Change it
curl -k -X POST https://auth.local/actuator/loggers/com.anpks \
  -H "Content-Type: application/json" \
  -d '{"configuredLevel": "DEBUG"}'
```

Useful for debugging production without restart. Disable in production unless secured with auth.

### Don't Over-Log

Common mistake: logging every method entry/exit. Generates noise, fills disk, slows queries.

Log what matters: business events, errors, slow operations. Skip what doesn't: routine method calls, every request header.

---

## Adding Custom Context to Logs

Beyond standard fields, you'll want to log custom context like userId, requestId, correlationId.

### Using MDC (Mapped Diagnostic Context)

Logback's MDC lets you attach arbitrary key-value pairs to all logs in a thread:

```java
import org.slf4j.MDC;

public Response handleRequest(Request req) {
    MDC.put("user.id", req.getUserId());
    MDC.put("request.id", req.getRequestId());
    try {
        log.info("Processing request");
        // ... your logic — every log line in this thread now includes user.id and request.id
        return result;
    } finally {
        MDC.clear();   // CRITICAL — prevents context leaking to next request
    }
}
```

With ECS structured logging, MDC values automatically appear as JSON fields:

```json
{"@timestamp":"...","log.level":"INFO","message":"Processing request","user.id":"123","request.id":"abc"}
```

Now you can query:

```logql
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | user_id="123"
```

(Note: LogQL replaces dots with underscores in JSON field names. `user.id` becomes `user_id` in the query.)

### Request ID via Filter

A common pattern: assign every request a unique ID, log it on every line for that request, return it in response headers so users can quote it.

```java
@Component
public class RequestIdFilter extends OncePerRequestFilter {
    
    @Override
    protected void doFilterInternal(HttpServletRequest req, 
                                     HttpServletResponse res, 
                                     FilterChain chain) throws ServletException, IOException {
        String requestId = req.getHeader("X-Request-Id");
        if (requestId == null) {
            requestId = UUID.randomUUID().toString();
        }
        
        MDC.put("request.id", requestId);
        res.setHeader("X-Request-Id", requestId);
        
        try {
            chain.doFilter(req, res);
        } finally {
            MDC.clear();
        }
    }
}
```

Now if a user reports "I got error code XYZ at 2:15 PM" they can also give you the request ID from their response, and you can find every log line for that specific request.

### Standard MDC Fields Worth Adding

For HTTP services:
- `request.id` — unique per request
- `user.id` — authenticated user (when present)
- `tenant.id` — for multi-tenant apps
- `trace.id` — for distributed tracing (auto-set if using OpenTelemetry)
- `http.method` — GET, POST, etc.
- `http.path` — request path

---

## Correlating Logs With Metrics

A killer feature of having Prometheus + Loki in Grafana: you can build dashboards that combine both.

### Pattern 1: Side-by-Side Panels

Build a dashboard with:
- Top panel: request rate from Prometheus
- Bottom panel: live log stream from Loki

When you see a metric anomaly, you can scroll the logs to the matching time and see what was happening.

### Pattern 2: Click-Through From Metric to Logs

In a Grafana panel, you can configure a "data link" that, when clicked on a data point, opens Explore with a Loki query at that timestamp.

This lets you: see a latency spike → click → see logs around that moment.

### Pattern 3: Log-Based Metrics

Sometimes you want metrics based on log content (e.g., "error rate"). Use LogQL's `count_over_time`:

```logql
sum(count_over_time({namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__="" | level="ERROR" [1m]))
```

This generates a numeric series Grafana can graph and alert on. Useful when you don't have a direct metric for the thing you care about.

### Pattern 4: Trace-Driven Logs

When you add distributed tracing later (OpenTelemetry → Tempo/Jaeger), traces and logs link via trace IDs. Click a slow request in the trace UI → see all logs for that exact request.

We're not there yet — but logging with trace IDs (via MDC) sets you up for this.

---

## Production Considerations

What we built in minikube is fine for learning. Production has additional concerns.

### Retention

Loki defaults to keeping logs forever. Production needs explicit retention:

```yaml
# Loki config
limits_config:
  retention_period: 90d   # keep 90 days

compactor:
  retention_enabled: true
```

90 days is a common compliance baseline. Adjust based on your needs and budget.

### Volume

A typical Java service emits 1-10 KB of log per request. At 100 requests/sec, that's 100 KB/sec, 8 GB/day. Plan storage accordingly.

Reduce volume by:
- Setting non-debug log levels in production
- Sampling routine logs (log every 100th request, not all)
- Compressing log lines (some fields like timestamp/level are highly compressible)

### Cost (in Cloud)

- Loki on S3: cheap (~$0.023/GB/month for S3 Standard)
- CloudWatch Logs: $0.50/GB ingested + $0.03/GB stored
- Datadog: $1.06/GB ingested (15-day retention)
- Splunk: even pricier

For high-volume services, log cost can rival compute cost. Architectural choices (sampling, log level discipline) matter.

### Multi-Cluster

In production with multiple clusters (dev/staging/prod, multi-region), you typically have:
- One Loki cluster per region (latency, locality)
- Grafana with multiple Loki data sources
- A `cluster` label on every log line for filtering

### Sensitive Data

Logs can leak credentials, tokens, PII. In production:
- Filter sensitive fields (passwords, tokens, SSNs) before logging
- Use Logback filters or logging helpers to redact
- Audit logs for accidental sensitive output periodically
- Encrypt logs in transit (Loki supports TLS) and at rest (S3 bucket encryption)

### Alerts on Log Patterns

Loki supports alerting via the Ruler component:

```yaml
groups:
  - name: log-alerts
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate({namespace="auth-service"} | json | line_format "{{.log}}" | json | level="ERROR" [5m])) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "auth-service is producing >1 error per second"
```

Same alert routing as Prometheus alerts (Alertmanager).

---

## Troubleshooting

### "No data" in Grafana Explore

Likely causes:

1. **Promtail not shipping** — check `k logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20`
2. **Wrong label** — your label values may not match. Use the label browser: click the curly braces icon in Explore
3. **Time range** — make sure Grafana's time range overlaps with when logs were produced
4. **Pod doesn't exist** — verify with `k get pods -n auth-service`

### Loki Data Source "Unable to Connect"

Despite the error, query in Explore often works. The connection test endpoint can be unreliable. Try a real query first.

If queries also fail:

```bash
# Verify Loki is alive
k logs -n monitoring loki-0 --tail=20

# Test from inside Grafana pod
GRAFANA_POD=$(k get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
k exec -n monitoring $GRAFANA_POD -c grafana -- wget -qO- --timeout=5 http://loki:3100/ready
# Should return: ready
```

### Logs Show Up But Aren't JSON

After enabling structured logging, logs might still appear as text. Check:

1. **Pod restarted with new image?**
   ```bash
   k describe pod -n auth-service -l app.kubernetes.io/name=auth-service | grep "Image:"
   ```
   Confirm it's the new SHA, not an old one.

2. **ConfigMap updated?**
   ```bash
   k get configmap auth-service-config -n auth-service -o yaml | grep -A 5 "structured"
   ```
   The base ConfigMap also contains application.yaml — if you only updated the JAR's version, the ConfigMap version overrides it.

3. **Spring Boot version >= 3.4?**
   ```bash
   grep -A 2 spring-boot-starter-parent auth-service/pom.xml
   ```
   Older versions don't have structured logging.

### JSON Logs Appear But Queries Don't Parse Them

Remember the two-layer JSON. Use the full parsing pipeline:

```logql
{namespace="auth-service"} | json | line_format "{{.log}}" | json | __error__=""
```

If you skip the first `json | line_format "{{.log}}"`, you're parsing the outer container wrapper, not your app's logs.

### High Memory Usage in Loki

Loki memory grows with active streams (label combinations). If you log with high-cardinality labels (like user_id), Loki struggles.

Symptoms: OOMKilled, slow queries.

Fix: don't put high-cardinality values in labels. Keep labels low-cardinality (namespace, pod, container, level). Use line content for high-cardinality data (user_id, request_id should be IN the log line, not a label).

### Promtail Missing Pods

Check that Promtail can reach the K8s API:

```bash
k logs -n monitoring -l app.kubernetes.io/name=promtail --tail=30
```

Look for errors. Typically RBAC — Promtail needs read access to pods/namespaces. The Helm chart sets this up, but a manual install or RBAC restriction can break it.

---

_Last updated: 2026-06-04. Update when adding distributed tracing, custom metric extraction from logs, or migrating to AWS managed logging._
