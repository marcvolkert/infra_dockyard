# PostgREST Tandem Helm Chart

PostgreSQL database + PostgREST API in a single Helm chart.

## Quick Start

```bash
helm install my-release ./chart
```

## Configuration

The chart supports minimal configuration. Key values:

| Key | Default | Description |
|-----|---------|-------------|
| `postgres.image` | `localhost/postgrest-db:16` | PostgreSQL image |
| `postgres.password` | `change-me` | PostgreSQL superuser password |
| `postgres.authenticatorPassword` | `change-me-too` | PostgREST authenticator password |
| `postgres.storageSize` | `10Gi` | PVC storage size |
| `postgrest.image` | `postgrest/postgrest:latest` | PostgREST image |
| `postgrest.port` | `3000` | PostgREST API port |

## Custom Values

```bash
helm install my-release ./chart \
  --set postgres.password=my-secret-password \
  --set postgres.storageSize=50Gi \
  --set postgrest.image=postgrest/postgrest:v12.0.0
```

Or with a values file:

```bash
helm install my-release ./chart -f my-values.yaml
```

## Components

- **PostgreSQL**: StatefulSet with persistent storage, headless service
- **PostgREST**: Deployment, ClusterIP service for HTTP API

## Access

Port-forward to the PostgREST API:

```bash
kubectl port-forward svc/postgrest-tandem-postgrest 3000:3000
```

Then access at `http://localhost:3000`
