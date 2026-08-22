# postgrest-tandem

PostgreSQL database + PostgREST API, deployed together as a single Helm
release ("tandem").

## Layout

- [`chart/`](chart/README.md) — Helm chart deploying the PostgreSQL
  StatefulSet and the PostgREST Deployment/Service.
- [`image/`](image/README.md) — custom PostgreSQL container image, pre-wired
  for PostgREST (JWT secret management, auth schema, login RPC bootstrap).

## Quick start

```bash
# 1. (Optional) Build the custom Postgres image for PostgREST.
podman build -t localhost/postgrest-db:16 \
  -f ./image/Containerfile ./image

# 2. Install the tandem. Override the default credentials!
helm upgrade --install postgrest-tandem ./chart \
  --namespace postgrest-tandem --create-namespace \
  --set database.auth.password=$(openssl rand -base64 24) \
  --set database.auth.authenticatorPassword=$(openssl rand -base64 24)

# 3. Or keep credentials in a local (gitignored) values file:
helm upgrade --install postgrest-tandem ./chart \
  --namespace postgrest-tandem --create-namespace \
  -f my.values.local.yaml
```

To reach the API locally:

```bash
kubectl -n postgrest-tandem port-forward svc/postgrest-service 3000:3000
```

See [`chart/README.md`](chart/README.md) for configuration values and
[`image/README.md`](image/README.md) for how the database image wires up
roles, schemas, and JWT handling for PostgREST.

## Security notes

- **Default credentials in `chart/values.yaml` are dev placeholders.**
  Override on every install. The `*.local.yaml` and `*.secret.yaml` patterns
  are gitignored — use them for real passwords.
- For production, point the chart at a Secret managed by
  SealedSecrets / ExternalSecrets / SOPS instead of templating one.
- For real HA / backups, swap this chart for an operator like CloudNativePG.
