# Observability Reference

> **Purpose**: Set up Prometheus + Grafana for the auth-service, understand how observability works in Kubernetes, and know what to monitor in production. Read this when you need to add monitoring to a service, debug a performance issue, or set up alerts.

---

## Table of Contents

1. [Observability in 60 Seconds](#observability-in-60-seconds)
2. [The Three Pillars](#the-three-pillars)
3. [How Prometheus Works](#how-prometheus-works)
4. [The Architecture We're Building](#the-architecture-we-are-building)
5. [Setup — kube-prometheus-stack](#setup--kube-prometheus-stack)
6. [Exposing Metrics from Spring Boot](#exposing-metrics-from-spring-boot)
7. [Telling Prometheus to Scrape auth-service](#telling-prometheus-to-scrape-auth-service)
8. [Accessing Prometheus and Grafana](#accessing-prometheus-and-grafana)
9. [PromQL Crash Course](#promql-crash-course)
10. [Building Your First Dashboard](#building-your-first-dashboard)
11. [What to Actually Monitor — RED and USE](#what-to-actually-monitor--red-and-use)
12. [Adding Custom Metrics to Your Code](#adding-custom-metrics-to-your-code)
13. [Alerting Basics](#alerting-basics)
14. [Production Path — AWS Managed Services](#production-path--aws-managed-services)
15. [Troubleshooting](#troubleshooting)

---

## Observability in 60 Seconds

You can't fix what you can't see. Observability is the practice of making your system's internals visible from the outside.

Three signals tell you what's happening:

- **Metrics** — Numeric measurements over time (request rate, latency, memory)
- **Logs** — Text records of discrete events (errors, requests, state changes)
- **Traces** — Path of a request through multiple services

For a single service like auth-service, **metrics are the highest-leverage starting point**. They tell you:

- Is the service handling traffic?
- How fast is it responding?
- Is it about to fall over (memory, CPU, connections)?
- Are errors increasing?

Metrics also drive alerting — "wake me up if error rate exceeds 5%" needs numeric data, not log searches.

---

## The Three Pillars

| Signal      | What it answers                                                 | Storage                  | Query language |
| ----------- | --------------------------------------------------------------- | ------------------------ | -------------- |
| **Metrics** | "How many?" "How fast?" "What's trending?"                      | Prometheus (time-series) | PromQL         |
| **Logs**    | "What exactly happened at 14:23?" "What was the error message?" | Loki / CloudWatch / ELK  | LogQL / Lucene |
| **Traces**  | "Why did this one request take 8 seconds?"                      | Tempo / Jaeger / X-Ray   | TraceQL        |

We're focusing on metrics. Logs and traces come later (separate docs when you add them).

### Why Metrics First

- Cheap to collect and store
- Drive alerts directly (logs/traces usually feed into metrics for alerting)
- Show **trends** — a single log line says "request was slow"; metrics show "requests have been getting slower for 3 days"
- Aggregate across all requests, not just the ones you happened to log

### When Metrics Aren't Enough

- "Why is error rate up?" → metric tells you it's up, log tells you WHY
- "Why does this one user see slowness?" → traces show their request path
- "Did we deploy the bug at 14:00?" → metrics show timing, logs/traces show specifics

A complete observability setup eventually has all three. Start with metrics.

---

## How Prometheus Works

### Pull-Based Scraping

This is the most important Prometheus concept and it surprises everyone:

**Prometheus pulls metrics. Your app doesn't push them.**

```
Prometheus              auth-service pod
──────────              ────────────────

Every 15 seconds:
   "GET /actuator/prometheus"  ──HTTP→  Spring Boot returns:
                                        # HELP jvm_memory_used_bytes ...
                                        # TYPE jvm_memory_used_bytes gauge
                                        jvm_memory_used_bytes{area="heap"} 134217728
                                        http_server_requests_seconds_count{...} 1543
                                        ...

   Parse, store with timestamp
```

Your app exposes a `/metrics` endpoint that returns plain text in Prometheus exposition format. Prometheus visits this endpoint regularly and stores the values.

### Why Pull, Not Push?

This is a controversial design choice. Reasons:

- **Service discovery is centralized** — Prometheus controls what gets scraped, not the apps
- **Health checking is free** — if scraping fails, that itself is a signal
- **Apps don't need to know where Prometheus lives** — they just expose `/metrics`
- **Easier debugging** — `curl /actuator/prometheus` shows exactly what Prometheus sees

Push-based systems (Datadog, StatsD) have their own tradeoffs — better for serverless/short-lived processes, worse for service discovery in K8s.

### How Prometheus Finds Things to Scrape

In Kubernetes, Prometheus uses ServiceMonitor resources (custom resources from the operator):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: auth-service
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: auth-service
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
```

This tells the Prometheus operator: "Find Services with label `app.kubernetes.io/name=auth-service`, look at their `http` port, hit `/actuator/prometheus`, scrape every 30 seconds."

Prometheus then automatically discovers any new pods of auth-service as they come up. No manual config.

### What Gets Stored

Each metric is a name + labels + value + timestamp:

```
http_server_requests_seconds_count{method="GET",uri="/api/users",status="200"} 1543 @ 2026-06-01T10:00:00Z
http_server_requests_seconds_count{method="GET",uri="/api/users",status="200"} 1547 @ 2026-06-01T10:00:15Z
http_server_requests_seconds_count{method="POST",uri="/api/users",status="201"} 23 @ 2026-06-01T10:00:00Z
```

Labels make metrics multi-dimensional. The same metric name `http_server_requests_seconds_count` can be sliced by method, URI, status, etc.

### Metric Types

Prometheus has four types:

| Type          | Behavior                              | Example                                  |
| ------------- | ------------------------------------- | ---------------------------------------- |
| **Counter**   | Only goes up (resets only on restart) | Total HTTP requests, total errors        |
| **Gauge**     | Goes up or down                       | Current memory usage, active connections |
| **Histogram** | Distribution of values                | Request latency buckets (p50, p99)       |
| **Summary**   | Similar to histogram, different math  | Pre-computed quantiles                   |

For most cases, you use Counter and Gauge. Histograms are how you measure latency.

---

## The Architecture We Are Building

```
┌───────────────────────────────────────────────────────────────────┐
│  minikube cluster                                                  │
│                                                                    │
│  ┌─────────────────┐    ┌─────────────────────────────────────┐   │
│  │  auth-service   │    │  monitoring namespace                │   │
│  │  pod            │    │                                      │   │
│  │  /actuator/     │◄───┼─── Prometheus (scrapes every 30s)    │   │
│  │  prometheus     │    │      │                               │   │
│  └─────────────────┘    │      │ stores time-series            │   │
│                         │      ▼                               │   │
│  ┌─────────────────┐    │   ┌──────────────┐                  │   │
│  │  postgres pod   │    │   │ Prometheus DB │                  │   │
│  │  (no metrics    │    │   └──────┬───────┘                  │   │
│  │   yet)          │    │          │ queries                  │   │
│  └─────────────────┘    │          ▼                          │   │
│                         │   ┌──────────────┐                  │   │
│  ┌─────────────────┐    │   │   Grafana    │ ← you view here  │   │
│  │  ingress-nginx  │────┼──►│              │                  │   │
│  │  (exposes its   │    │   └──────────────┘                  │   │
│  │   own metrics)  │    │          │                          │   │
│  └─────────────────┘    │          │ port-forward             │   │
│                         └──────────┼──────────────────────────┘   │
│                                    │                              │
└────────────────────────────────────┼──────────────────────────────┘
                                     ▼
                              http://localhost:3000
                              (your browser)
```

Components:

- **Prometheus** — scrapes metrics, stores time-series, answers queries
- **Grafana** — visualization layer, queries Prometheus, renders dashboards
- **Alertmanager** — receives alerts from Prometheus, routes to Slack/PagerDuty/email
- **Node Exporter** — runs on the minikube node, exposes node-level metrics (CPU, disk, memory)
- **kube-state-metrics** — converts Kubernetes API state into metrics (pod count, deployment status, etc.)

The kube-prometheus-stack Helm chart installs all of this with sane defaults and pre-built Grafana dashboards for Kubernetes itself.

---

## Setup — kube-prometheus-stack

### Install Helm if You Don't Have It

Helm is the package manager for Kubernetes. It installs complex stacks like the Prometheus operator with one command.

```bash
brew install helm
helm version
# Should show: version.BuildInfo{Version:"v3.x.x", ...}
```

### Add the Helm Repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

`helm repo update` is the Helm equivalent of `apt update` — refreshes the local index of available chart versions.

### Install the Stack

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.resources.requests.memory=400Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=600Mi \
  --set grafana.resources.requests.memory=100Mi \
  --set grafana.resources.limits.memory=200Mi
```

Breaking down the flags:

| Flag                                            | Meaning                                                                          |
| ----------------------------------------------- | -------------------------------------------------------------------------------- |
| `install monitoring`                            | Helm release name (so you can `helm upgrade monitoring ...` later)               |
| `prometheus-community/kube-prometheus-stack`    | Chart to install                                                                 |
| `--namespace monitoring`                        | Install in `monitoring` namespace                                                |
| `--create-namespace`                            | Create the namespace if missing                                                  |
| `serviceMonitorSelectorNilUsesHelmValues=false` | Make Prometheus discover ServiceMonitors in ANY namespace, not just monitoring's |
| `retention=7d`                                  | Keep 7 days of metrics (default 15d uses more disk)                              |
| `resources.requests/limits.memory`              | Cap memory usage for minikube's tight RAM                                        |

The install takes 1-2 minutes. It creates:

- Prometheus pod (~500 MB)
- Grafana pod (~150 MB)
- Alertmanager pod (~50 MB)
- Node Exporter (DaemonSet, runs on every node)
- kube-state-metrics
- Multiple Custom Resource Definitions (ServiceMonitor, PrometheusRule, etc.)
- Default ServiceMonitors that scrape the Kubernetes control plane

### Verify

```bash
kubectl get pods -n monitoring
```

Wait for all pods to be `Running`. Should take 60-90 seconds. You'll see something like:

```
NAME                                                     READY   STATUS    RESTARTS   AGE
alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2     Running   0          2m
monitoring-grafana-xxx                                   3/3     Running   0          2m
monitoring-kube-prometheus-operator-xxx                  1/1     Running   0          2m
monitoring-kube-state-metrics-xxx                        1/1     Running   0          2m
monitoring-prometheus-node-exporter-xxx                  1/1     Running   0          2m
prometheus-monitoring-kube-prometheus-prometheus-0       2/2     Running   0          2m
```

If any are pending, check resources:

```bash
kubectl describe pod -n monitoring <pod-name> | grep -A 5 "Events"
```

Usually the issue is memory pressure on minikube. Bump minikube memory or skip the optional components.

---

## Exposing Metrics from Spring Boot

For Prometheus to scrape your service, the service must expose metrics. In Spring Boot, this is Micrometer + Spring Actuator.

### Add the Dependency

In your `auth-service/pom.xml`:

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>

<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
    <scope>runtime</scope>
</dependency>
```

The `actuator` starter adds the management endpoints. `micrometer-registry-prometheus` adds the bridge that formats metrics in Prometheus' text format.

You may already have these. Check with:

```bash
grep -A 2 "spring-boot-starter-actuator\|micrometer-registry-prometheus" auth-service/pom.xml
```

### Configure application.yaml

In your `auth-service/src/main/resources/application.yaml` (and corresponding ConfigMap):

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
  endpoint:
    health:
      probes:
        enabled: true
      show-details: when-authorized
  metrics:
    tags:
      application: ${spring.application.name}
      environment: ${SPRING_PROFILES_ACTIVE:dev}
```

Two important parts:

1. **`exposure.include`** must contain `prometheus` — otherwise the `/actuator/prometheus` endpoint returns 404
2. **`management.metrics.tags`** adds labels to every metric. The `application` label distinguishes auth-service from other services later; `environment` lets you filter dev vs prod data in the same dashboard

### Verify Locally

After rebuilding and redeploying:

```bash
# Port-forward auth-service
kubectl port-forward -n auth-service svc/auth-service 8081:8081

# In another terminal
curl http://localhost:8081/actuator/prometheus | head -50
```

You should see a wall of metrics like:

```
# HELP jvm_memory_used_bytes The amount of used memory
# TYPE jvm_memory_used_bytes gauge
jvm_memory_used_bytes{area="heap",id="G1 Survivor Space",application="auth-service",environment="dev"} 1.6777216E7
jvm_memory_used_bytes{area="heap",id="G1 Old Gen",application="auth-service",environment="dev"} 7.1303168E7

# HELP http_server_requests_seconds Duration of HTTP server request handling
# TYPE http_server_requests_seconds histogram
http_server_requests_seconds_count{...,uri="/actuator/health",status="200"} 24
http_server_requests_seconds_sum{...,uri="/actuator/health",status="200"} 0.187543
```

**The `# HELP` and `# TYPE` lines tell Prometheus what each metric is.** The numeric lines are values.

What you get out of the box from Spring Boot:

- `jvm_memory_*` — heap, non-heap, by region (Eden, Survivor, etc.)
- `jvm_gc_*` — garbage collection counts and durations
- `jvm_threads_*` — thread counts by state
- `process_cpu_usage` — CPU utilization
- `system_load_average_1m` — system load
- `http_server_requests_seconds*` — request count + duration histogram, per endpoint
- `hikaricp_connections_*` — DB connection pool (active, idle, pending)
- `tomcat_*` — Tomcat connector metrics
- `logback_events_total` — log events by level

That's >100 metrics out of the box, before you write a single line of custom metric code.

---

## Telling Prometheus to Scrape auth-service

Just exposing `/actuator/prometheus` isn't enough — Prometheus needs to know about it. You create a **ServiceMonitor** resource.

### Add the ServiceMonitor

Create `k8s/base/auth-service/servicemonitor.yml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: auth-service
  namespace: auth-service
  labels:
    app.kubernetes.io/name: auth-service
    app.kubernetes.io/part-of: auth-service
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: auth-service
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
      scrapeTimeout: 10s
```

What this does:

- **`selector.matchLabels`** — Prometheus finds Services with the label `app.kubernetes.io/name=auth-service`
- **`endpoints.port: http`** — references the named port `http` from the Service spec
- **`path`** — what URL to hit on each pod
- **`interval`** — how often to scrape (30 seconds is plenty for most apps)
- **`scrapeTimeout`** — fail the scrape after 10 seconds

The ServiceMonitor lives in your service's namespace (`auth-service`), not in `monitoring`. Prometheus watches all namespaces (thanks to the flag we set during install).

### Add to Kustomization

Update `k8s/base/auth-service/kustomization.yml`:

```yaml
resources:
  - namespace.yml
  - configmap.yml
  - postgres-service.yml
  - postgres-statefulset.yml
  - deployment.yml
  - service.yml
  - ingress.yml
  - hpa.yml
  - servicemonitor.yml # ← add this
```

### Apply

```bash
kubectl apply -k k8s/overlays/dev/auth-service
```

### Verify Prometheus Picked It Up

Port-forward Prometheus:

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Open `http://localhost:9090/targets` in your browser.

You should see a section called something like `serviceMonitor/auth-service/auth-service/0`. Status should be `UP` (green). If it shows `DOWN`:

- Click the error message to see what's wrong
- Common: wrong port name, wrong path, pod not actually exposing metrics

### Confirm Metrics Are Flowing

In Prometheus UI, click "Graph" tab. Type:

```promql
http_server_requests_seconds_count{application="auth-service"}
```

Click "Execute". You should see request counts for various endpoints. Hit some endpoints (e.g., `curl https://auth.local/actuator/health` a few times) and the values should grow.

---

## Accessing Prometheus and Grafana

Both UIs are inside the cluster. You access them via port-forward.

### Prometheus UI

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Open `http://localhost:9090`.

What you use Prometheus for directly:

- **Targets** (`/targets`) — see what's being scraped, and if scrapes are failing
- **Graph** — ad-hoc PromQL queries to debug
- **Alerts** (`/alerts`) — see current alert state
- **Rules** (`/rules`) — see what recording/alerting rules are configured

Prometheus's UI is for engineering, not pretty dashboards. For dashboards, use Grafana.

### Grafana UI

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Open `http://localhost:3000`.

**Default credentials**:

- Username: `admin`
- Password: get it with:
  ```bash
  kubectl get secret -n monitoring monitoring-grafana \
    -o jsonpath="{.data.admin-password}" | base64 -d
  ```

What you see at first login:

- Pre-installed dashboards for Kubernetes (under "Dashboards" in sidebar)
  - "Kubernetes / Compute Resources / Cluster"
  - "Kubernetes / Compute Resources / Namespace (Pods)"
  - "Node Exporter / Nodes"
  - "Kubernetes / API server"
  - …about 20 more

Browse these to see what's possible. The "Kubernetes / Compute Resources / Namespace (Pods)" dashboard filtered to `auth-service` namespace will already show CPU, memory, and network for your pods — even before you build anything custom.

### Daily Workflow

You'll typically have **two terminals** open all day:

```
Terminal 1: minikube tunnel
Terminal 2: kubectl port-forward grafana
```

Or write a small script:

```bash
# scripts/port-forward-monitoring.sh
#!/bin/bash
trap 'kill %1; kill %2' EXIT
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
wait
```

Then `./scripts/port-forward-monitoring.sh` opens both. Ctrl+C cleans up both.

---

## PromQL Crash Course

PromQL is Prometheus' query language. The basics get you 90% of what you need.

### Selecting Metrics

```promql
# All values of this metric, all labels
http_server_requests_seconds_count

# Filter by label
http_server_requests_seconds_count{application="auth-service"}

# Multiple filters
http_server_requests_seconds_count{application="auth-service", method="GET"}

# Negation
http_server_requests_seconds_count{status!="200"}

# Regex match
http_server_requests_seconds_count{uri=~"/api/.*"}
```

### Working with Counters

Counters always go up. To see "rate per second", use `rate()`:

```promql
# Requests per second over the last 5 minutes
rate(http_server_requests_seconds_count{application="auth-service"}[5m])

# Sum across all pods
sum(rate(http_server_requests_seconds_count{application="auth-service"}[5m]))

# Per endpoint
sum by (uri) (rate(http_server_requests_seconds_count{application="auth-service"}[5m]))
```

**The `[5m]` syntax** is a "range vector" — gives Prometheus the last 5 minutes of data so `rate()` can compute a per-second rate.

### Working with Gauges

Gauges are current values, no special function needed:

```promql
# Current JVM heap usage
jvm_memory_used_bytes{application="auth-service", area="heap"}

# Sum heap across all pods
sum(jvm_memory_used_bytes{application="auth-service", area="heap"})

# Percentage of max heap
jvm_memory_used_bytes{application="auth-service", area="heap"}
  /
jvm_memory_max_bytes{application="auth-service", area="heap"}
```

### Working with Histograms

Histograms are for distributions (latency, sizes). They produce three series per metric:

- `*_count` — total observations (a counter)
- `*_sum` — sum of observations (a counter)
- `*_bucket` — cumulative counts in buckets

For latency, you usually want percentiles:

```promql
# p95 latency over last 5 minutes
histogram_quantile(0.95,
  sum by (le) (
    rate(http_server_requests_seconds_bucket{application="auth-service"}[5m])
  )
)

# p99 latency per endpoint
histogram_quantile(0.99,
  sum by (uri, le) (
    rate(http_server_requests_seconds_bucket{application="auth-service"}[5m])
  )
)
```

This looks intimidating; with experience it's pattern-matchy. The pattern for percentiles is:

```
histogram_quantile(<percentile>,
  sum by (le, <other labels you want>) (
    rate(<metric>_bucket[<range>])
  )
)
```

### Common PromQL Patterns

| You want                  | PromQL                                                                         |
| ------------------------- | ------------------------------------------------------------------------------ |
| Request rate (per second) | `sum(rate(http_server_requests_seconds_count{...}[5m]))`                       |
| Error rate                | `sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))`             |
| Error percentage          | `sum(rate(http_..._count{status=~"5.."}[5m])) / sum(rate(http_..._count[5m]))` |
| P50/P95/P99 latency       | `histogram_quantile(0.95, sum by (le) (rate(http_..._bucket[5m])))`            |
| Memory usage              | `jvm_memory_used_bytes{area="heap"}`                                           |
| CPU usage                 | `process_cpu_usage{application="auth-service"}`                                |
| DB connections used       | `hikaricp_connections_active`                                                  |
| GC pause time             | `rate(jvm_gc_pause_seconds_sum[5m])`                                           |

---

## Building Your First Dashboard

In Grafana, dashboards consist of **panels**. Each panel runs one or more PromQL queries and renders the result.

### Create a Dashboard

1. Grafana → "Dashboards" → "New" → "New dashboard"
2. Click "Add visualization"
3. Select "Prometheus" as the data source

### Panel 1 — Request Rate

- **Query**: `sum(rate(http_server_requests_seconds_count{application="auth-service"}[5m]))`
- **Title**: "Request rate (req/s)"
- **Visualization**: Time series
- **Unit**: requests/sec

Save panel.

### Panel 2 — Error Rate

- **Query**: `sum(rate(http_server_requests_seconds_count{application="auth-service",status=~"5.."}[5m]))`
- **Title**: "Error rate (5xx/sec)"
- **Unit**: errors/sec

### Panel 3 — P95 Latency

- **Query**: `histogram_quantile(0.95, sum by (le, uri) (rate(http_server_requests_seconds_bucket{application="auth-service"}[5m])))`
- **Title**: "P95 latency by endpoint"
- **Legend**: `{{uri}}`
- **Unit**: seconds

### Panel 4 — JVM Heap Usage

- **Query A**: `jvm_memory_used_bytes{application="auth-service",area="heap"}`
- **Query B**: `jvm_memory_max_bytes{application="auth-service",area="heap"}`
- **Title**: "JVM Heap (used vs max)"
- **Unit**: bytes (SI)

### Panel 5 — DB Connection Pool

- **Query**: `hikaricp_connections_active{application="auth-service"}`
- **Title**: "Active DB connections"

### Save the Dashboard

Click "Save dashboard" at the top right. Name it "auth-service overview." Choose a folder (or none).

### Export to JSON for Version Control

Grafana dashboards are JSON. You can commit them so they're not just in Grafana's database:

1. Dashboard → "Share" → "Export" → "Save to file"
2. Save the JSON as `monitoring/dashboards/auth-service-overview.json` in your repo

Now the dashboard config is version-controlled. If Grafana dies, you re-import.

---

## What to Actually Monitor — RED and USE

Two well-known frameworks tell you what to measure.

### RED — For Request-Driven Services (auth-service)

For services that handle requests (web, API, RPC), measure:

- **R**ate — requests per second
- **E**rrors — error rate (count or percentage)
- **D**uration — latency (P50, P95, P99)

These three numbers tell you "is my service healthy?" Almost any service problem shows up in one of them:

- Rate drops to zero? Service is down or upstream traffic stopped
- Error rate spikes? Something's broken
- Latency P95 climbs? Capacity issue, slow dependency, or memory pressure

For auth-service, your minimum dashboard is RED:

```promql
# Rate
sum(rate(http_server_requests_seconds_count{application="auth-service"}[5m]))

# Errors
sum(rate(http_server_requests_seconds_count{application="auth-service",status=~"5.."}[5m]))

# Duration
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{application="auth-service"}[5m])))
```

### USE — For Resources

For physical/virtual resources (CPU, memory, disk, network), measure:

- **U**tilization — what % is in use
- **S**aturation — what's queued/waiting
- **E**rrors — error count

For your pod:

```promql
# CPU utilization
process_cpu_usage{application="auth-service"}

# Memory utilization (heap)
jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"}

# DB connection saturation (pool exhausted = bad)
hikaricp_connections_pending{application="auth-service"}

# DB connection errors
hikaricp_connections_creation_failed_total{application="auth-service"}
```

### Putting It Together — A Production-Worthy Dashboard

Layout for auth-service:

```
┌────────────────────────┬────────────────────────┬────────────────────────┐
│ Request rate (RED)     │ Error rate (RED)       │ P95 latency (RED)      │
│ Single line graph      │ Single line graph      │ By endpoint            │
└────────────────────────┴────────────────────────┴────────────────────────┘
┌────────────────────────┬────────────────────────┬────────────────────────┐
│ JVM heap used vs max   │ GC pause time          │ Threads                │
│ (USE - mem)            │ (USE - mem saturation) │ (USE - threads)        │
└────────────────────────┴────────────────────────┴────────────────────────┘
┌────────────────────────┬────────────────────────┬────────────────────────┐
│ DB connections active  │ DB connections waiting │ Slow queries           │
│ (USE - DB util)        │ (USE - DB saturation)  │ (custom metric)        │
└────────────────────────┴────────────────────────┴────────────────────────┘
```

Nine panels gives you a complete picture of your service's health.

---

## Adding Custom Metrics to Your Code

Built-in metrics tell you about the JVM and HTTP. To monitor **business logic** — "logins per minute", "failed token validations", "users registered today" — you add custom metrics in Java code.

### Counter Example — Counting Logins

In your Java code:

```java
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Service;

@Service
public class AuthService {

    private final Counter successfulLogins;
    private final Counter failedLogins;

    public AuthService(MeterRegistry registry) {
        this.successfulLogins = Counter.builder("auth.login.success")
            .description("Total successful logins")
            .register(registry);

        this.failedLogins = Counter.builder("auth.login.failure")
            .description("Total failed logins")
            .tag("reason", "unknown")   // can be overridden per increment
            .register(registry);
    }

    public LoginResponse login(LoginRequest req) {
        try {
            // ... your login logic ...
            successfulLogins.increment();
            return response;
        } catch (BadCredentialsException e) {
            failedLogins.increment();
            // OR with a tag:
            // registry.counter("auth.login.failure", "reason", "bad_credentials").increment();
            throw e;
        }
    }
}
```

After redeploying, query in Prometheus:

```promql
rate(auth_login_success_total[5m])
rate(auth_login_failure_total[5m])
```

Note: Micrometer converts dots to underscores and adds `_total` to counters. `auth.login.success` becomes `auth_login_success_total` in Prometheus.

### Gauge Example — Active Sessions

```java
import io.micrometer.core.instrument.Gauge;

public AuthService(MeterRegistry registry, SessionStore sessions) {
    Gauge.builder("auth.sessions.active", sessions, SessionStore::activeCount)
        .description("Currently active user sessions")
        .register(registry);
}
```

The Gauge polls `sessions.activeCount()` whenever Prometheus scrapes. No need to call `increment` — it pulls the value dynamically.

### Timer Example — Measuring DB Operation Latency

```java
import io.micrometer.core.instrument.Timer;

private final Timer dbQueryTimer;

public AuthService(MeterRegistry registry) {
    this.dbQueryTimer = Timer.builder("auth.db.query")
        .description("Database query duration")
        .publishPercentileHistogram()   // exposes buckets for histogram_quantile
        .register(registry);
}

public User findUser(String username) {
    return dbQueryTimer.record(() -> userRepository.findByUsername(username));
}
```

Now you can query in PromQL:

```promql
# Average query time
rate(auth_db_query_seconds_sum[5m]) / rate(auth_db_query_seconds_count[5m])

# P95 query time
histogram_quantile(0.95, rate(auth_db_query_seconds_bucket[5m]))
```

### Tags vs. Different Metric Names

Use **tags** (Micrometer terminology — Prometheus calls them labels) instead of separate metric names:

```java
// GOOD — one metric with tags
registry.counter("auth.login.attempt", "result", "success").increment();
registry.counter("auth.login.attempt", "result", "failure").increment();

// BAD — separate metrics
registry.counter("auth.login.success").increment();
registry.counter("auth.login.failure").increment();
```

Tags let you slice the data later. Separate metrics force you to query each one independently.

### What to Measure

For an auth service, useful custom metrics:

- `auth.login.attempt` (tags: result, reason) — login attempts and outcomes
- `auth.token.validate` (tags: result) — token validation success/failure
- `auth.user.register` — new user registrations
- `auth.password.reset.requested` — password reset flows started
- `auth.session.duration` — how long sessions last (timer)
- `auth.failed.login.by.ip` (tags: ip_class) — rough rate-limiting visibility

Each tells a business story. Drops in registration rate, spikes in failed logins, unusual token validation patterns — these are early warnings.

---

## Alerting Basics

Metrics are useful for dashboards, but **alerts wake you up**. Alertmanager is the tool that routes alerts; Prometheus rules define them.

### Define an Alert

Create `k8s/base/auth-service/prometheusrules.yml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: auth-service-alerts
  namespace: auth-service
  labels:
    app.kubernetes.io/name: auth-service
spec:
  groups:
    - name: auth-service.rules
      interval: 30s
      rules:
        - alert: AuthServiceHighErrorRate
          expr: |
            sum(rate(http_server_requests_seconds_count{application="auth-service",status=~"5.."}[5m]))
            /
            sum(rate(http_server_requests_seconds_count{application="auth-service"}[5m]))
            > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "auth-service error rate above 5%"
            description: "Error rate has been {{ $value | humanizePercentage }} for the last 5 minutes."

        - alert: AuthServiceHighLatency
          expr: |
            histogram_quantile(0.95,
              sum by (le) (rate(http_server_requests_seconds_bucket{application="auth-service"}[5m]))
            ) > 1.0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "auth-service P95 latency above 1s"
            description: "P95 has been {{ $value }}s for 10 minutes."

        - alert: AuthServicePodNotReady
          expr: kube_pod_status_ready{namespace="auth-service",condition="true"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "auth-service pod not ready"
            description: "Pod {{ $labels.pod }} not ready for 5 minutes."
```

### How Alerts Work

- **`expr`** — the PromQL query that evaluates the condition
- **`for: 5m`** — must be true for 5 continuous minutes before firing (prevents flapping)
- **`labels.severity`** — used by Alertmanager to route to different channels
- **`annotations`** — human-readable details for the alert (with templating)

### Configure Alertmanager Routing

By default, Alertmanager comes with no real configuration. To send alerts to Slack:

```yaml
# Edit the alertmanager config
kubectl edit secret alertmanager-monitoring-kube-prometheus-alertmanager -n monitoring
```

The data is base64-encoded YAML. You'd decode, edit, re-encode. Cumbersome — better to use Helm values:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  --set alertmanager.config.global.slack_api_url=YOUR_WEBHOOK_URL \
  --set alertmanager.config.route.receiver=slack \
  --set 'alertmanager.config.receivers[0].name=slack' \
  --set 'alertmanager.config.receivers[0].slack_configs[0].channel=#alerts'
```

For real use, manage Alertmanager config via a Helm values file rather than CLI flags. Topic for a separate doc when you set up real alerting.

For learning, the in-Prometheus alert state is enough — see "Alerts" tab in Prometheus UI.

---

## Production Path — AWS Managed Services

When you move to AWS EKS, you can:

### Option 1: Self-hosted Prometheus + Grafana (Same as Dev)

Install the same kube-prometheus-stack on EKS. Same dashboards, same alerts. You manage retention, storage, scaling.

Pros: Same as dev, you understand it deeply
Cons: Operations overhead, scaling Prometheus is non-trivial past 10s of services

### Option 2: AWS Managed Prometheus + AWS Managed Grafana

AWS hosts both for you. Your apps still expose `/actuator/prometheus`; you install a Prometheus agent in EKS that forwards to AWS Managed Prometheus.

Pros: Zero ops for the monitoring stack itself
Cons: ~$70-100/month minimum, AWS-specific

### Option 3: Datadog

Replace everything with Datadog agent. Different metric paths (Datadog has its own metric names sometimes), but same conceptual approach.

Pros: One product for metrics + logs + traces + APM, polished UI
Cons: Cost scales fast — $15-30/host/month plus extras for logs/APM

### Option 4: Hybrid

Self-hosted Prometheus in EKS for cheap metric collection, AWS Managed Grafana for the UI. Common for cost-conscious teams.

For each option, the auth-service Spring Boot side is **identical**. You configure Spring to expose Prometheus metrics; what scrapes them is the only difference.

---

## Troubleshooting

### ServiceMonitor exists but Prometheus doesn't scrape

Check Prometheus targets UI (`http://localhost:9090/targets`):

- ServiceMonitor not showing at all → Prometheus operator isn't watching its namespace
  - Fix: when installing, ensure `serviceMonitorSelectorNilUsesHelmValues=false` (we did this)
- Target shows but status DOWN → scrape is failing
  - Click the error message for details
  - Common: wrong path, wrong port, /actuator/prometheus not enabled in app

### Metrics endpoint returns 404

Spring Boot doesn't have the prometheus endpoint enabled:

```bash
# Test directly
kubectl port-forward -n auth-service svc/auth-service 8081:8081
curl http://localhost:8081/actuator/prometheus

# If 404:
# 1. Check that micrometer-registry-prometheus is in pom.xml
# 2. Check application.yaml has "prometheus" in management.endpoints.web.exposure.include
# 3. Rebuild image, redeploy
```

### Grafana dashboard shows "No data"

Three layers to check:

1. **Is the metric being scraped?** Check Prometheus directly — `http://localhost:9090/graph` and run the query
2. **Is Grafana connected to Prometheus?** Configuration → Data sources → "Prometheus" should be there and "OK" when tested
3. **Is the query correct?** Add `{application="auth-service"}` filter, check label values exist

### Prometheus pod restarting / OOMKilled

Prometheus is memory-hungry. Default ~400 MB is enough for our setup. If OOMing:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --reuse-values \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi
```

Or reduce retention:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --reuse-values \
  --set prometheus.prometheusSpec.retention=3d
```

### "Too many open files" errors

Prometheus opens many files at scale. Increase ulimits or scale up. Not usually an issue in minikube.

### Custom metric not showing up

After deploying code with new metrics, verify in this order:

```bash
# 1. App is exposing it
kubectl port-forward -n auth-service svc/auth-service 8081:8081
curl http://localhost:8081/actuator/prometheus | grep auth_login

# 2. Prometheus is scraping it
# http://localhost:9090/graph → query "auth_login_success_total"

# 3. Grafana sees it
# Build a panel with that query
```

Common issue: Micrometer renames metrics (dots to underscores, `_total` suffix on counters). Check the actual exposed name with curl first.

---

_Last updated: 2026-06-01. Update when adding logs (Loki), traces (Tempo), or new monitoring patterns._
