# redis-test

Test environment for a Redis upgrade with Sentinel, available in two flavours:

| | [compose/](compose/) | [k8s/](k8s/) |
|---|---|---|
| **Tool** | Docker Compose | kubectl |
| **Versions** | 6.2 → 8.2 | 8.2 → 8.6 |
| **Upgrade method** | Manual step-by-step script | `kubectl set image` → rolling restart |
| **Rollback** | RDB restore | RDB restore via helper pod |
| **Good for** | Understanding the upgrade mechanics | Understanding how k8s handles stateful workloads |

## Quick start

```bash
# Docker Compose
cd compose
make up
make insert
make upgrade
make verify

# Kubernetes (k3d)
cd k8s
make up
make insert
make upgrade
make verify
```

See each directory for the full README.
