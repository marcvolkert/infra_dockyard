## Required repository settings

Apply these GitHub branch protection settings so the workflow checks in this repository are enforced:

- Protect `dev` and require these status checks:
  - `validate-branch-name`
  - `build`
  - `integration-test`
- Protect `main` and require these status checks:
  - `validate-branch-name`
  - `build`
  - `integration-test`
- Require pull requests before merging into `dev` or `main`
- Restrict pushes to protected branches as appropriate for your team

Supported branch names for pull requests targeting `dev` or `main`:

- `feature/*`
- `copilot/*`
- `dev`
- `main`

Release workflow behavior:

- Pull requests targeting `dev` or `main` always run branch-name validation, image build, and integration tests
- Pushing a version tag on a commit reachable from `dev` but not `main` publishes a pre-release image and GitHub pre-release
- Pushing a stable version tag on a commit reachable from `main` publishes the release image and GitHub release
