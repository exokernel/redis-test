# redis-test

Test environment for a Redis 6.2 → 8.2 upgrade with Sentinel, available in two flavours:

| | [compose/](compose/) | [k8s/](k8s/) |
|---|---|---|
| **Tool** | Docker Compose | Helm + kubectl |
| **Upgrade method** | Manual step-by-step script | `helm upgrade` → rolling restart |
| **Rollback** | RDB restore | `helm rollback` |
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
