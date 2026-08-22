# infra_dockyard

Monorepo for personal Kubernetes infrastructure, grouped by component:
every top-level directory is one deployable unit and contains everything
related to it (chart, image, etc.).

## Layout

```
.
└── postgrest-tandem/        # one folder per component
    ├── chart/                # Helm chart (templates/, values.yaml, Chart.yaml)
    └── image/                # Container image (Containerfile, README.md, initdb/)
```

### Conventions

- One **component** per top-level directory. Anything related to it (chart,
  custom image, init scripts) lives inside it.
- `<component>/chart/` is a standard Helm chart with sensible defaults in
  `values.yaml`.
- `<component>/image/` is optional; only present if the component ships a
  custom container image.

## Quick start

```bash
# 1. (Optional) Build the custom Postgres image for PostgREST.
podman build -t localhost/postgrest-db:16 \
  -f ./postgrest-tandem/image/Containerfile ./postgrest-tandem/image

# 2. Install the tandem. Override the default credentials!
helm upgrade --install postgrest-tandem ./postgrest-tandem/chart \
  --namespace postgrest-tandem --create-namespace \
  --set database.auth.password=$(openssl rand -base64 24) \
  --set database.auth.authenticatorPassword=$(openssl rand -base64 24)

# 3. Or keep credentials in a local (gitignored) values file:
helm upgrade --install postgrest-tandem ./postgrest-tandem/chart \
  --namespace postgrest-tandem --create-namespace \
  -f my.values.local.yaml
```

The chart deploys the PostgreSQL backend image plus a PostgREST API service.

To reach the API locally:

```bash
kubectl -n postgrest-tandem port-forward svc/postgrest-service 3000:3000
```

## Adding a new component

1. `mkdir -p <name>/chart/templates` and start from `postgrest-tandem/chart/`.
2. If it needs a custom image, scaffold `<name>/image/`.
3. `helm upgrade --install <name> ./<name>/chart -n <name> --create-namespace`.

## Security notes

- **Default credentials in `values.yaml` are dev placeholders.** Override on
  every install. The `*.local.yaml` and `*.secret.yaml` patterns are
  gitignored — use them for real passwords.
- For production, point the chart at a Secret managed by
  SealedSecrets / ExternalSecrets / SOPS instead of templating one.
- For real HA / backups, swap this chart for an operator like CloudNativePG.
