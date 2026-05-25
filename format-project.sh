#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_FORMAT_FLAGS="${PG_FORMAT_FLAGS:--i}"
SHFMT_FLAGS="${SHFMT_FLAGS:--w -i 2 -ci -bn}"
YAMLFMT_FLAGS="${YAMLFMT_FLAGS:-}"
HADOLINT_FLAGS="${HADOLINT_FLAGS:---failure-threshold error}"

missing=()
for bin in pg_format shfmt yamlfmt hadolint; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    missing+=("$bin")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'Missing required tools: %s\n' "${missing[*]}"
  echo "Install on macOS with: brew install pgformatter shfmt yamlfmt hadolint"
  exit 1
fi

sql_files=()
while IFS= read -r -d '' f; do
  sql_files+=("$f")
done < <(find "$ROOT_DIR" -type f -name '*.sql' -print0)

sh_files=()
while IFS= read -r -d '' f; do
  sh_files+=("$f")
done < <(find "$ROOT_DIR" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.zsh' \) -print0)

yaml_files=()
while IFS= read -r -d '' f; do
  yaml_files+=("$f")
done < <(find "$ROOT_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) ! -path '*/chart/templates/*' -print0)

docker_files=()
while IFS= read -r -d '' f; do
  docker_files+=("$f")
done < <(find "$ROOT_DIR" -type f \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name 'Containerfile' -o -name 'Containerfile.*' \) -print0)

declare -a pg_flags=()
declare -a shfmt_flags=()
declare -a yamlfmt_flags=()
declare -a hadolint_flags=()

if [[ -n "$PG_FORMAT_FLAGS" ]]; then
  # shellcheck disable=SC2206
  pg_flags=($PG_FORMAT_FLAGS)
fi
if [[ -n "$SHFMT_FLAGS" ]]; then
  # shellcheck disable=SC2206
  shfmt_flags=($SHFMT_FLAGS)
fi
if [[ -n "$YAMLFMT_FLAGS" ]]; then
  # shellcheck disable=SC2206
  yamlfmt_flags=($YAMLFMT_FLAGS)
fi
if [[ -n "$HADOLINT_FLAGS" ]]; then
  # shellcheck disable=SC2206
  hadolint_flags=($HADOLINT_FLAGS)
fi

if [[ ${#sql_files[@]} -gt 0 ]]; then
  echo "Formatting SQL (${#sql_files[@]} files) with pg_format..."
  if [[ ${#pg_flags[@]} -gt 0 ]]; then
    LC_ALL=C LANG=C pg_format "${pg_flags[@]}" "${sql_files[@]}"
  else
    LC_ALL=C LANG=C pg_format "${sql_files[@]}"
  fi
else
  echo "No SQL files found."
fi

if [[ ${#sh_files[@]} -gt 0 ]]; then
  echo "Formatting Shell (${#sh_files[@]} files) with shfmt..."
  if [[ ${#shfmt_flags[@]} -gt 0 ]]; then
    shfmt "${shfmt_flags[@]}" "${sh_files[@]}"
  else
    shfmt "${sh_files[@]}"
  fi
else
  echo "No Shell script files found."
fi

if [[ ${#yaml_files[@]} -gt 0 ]]; then
  echo "Formatting YAML (${#yaml_files[@]} files) with yamlfmt..."
  if [[ ${#yamlfmt_flags[@]} -gt 0 ]]; then
    yamlfmt "${yamlfmt_flags[@]}" "${yaml_files[@]}"
  else
    yamlfmt "${yaml_files[@]}"
  fi
else
  echo "No YAML files found."
fi

if [[ ${#docker_files[@]} -gt 0 ]]; then
  echo "Linting Docker/Container files (${#docker_files[@]} files) with hadolint..."
  if [[ ${#hadolint_flags[@]} -gt 0 ]]; then
    hadolint "${hadolint_flags[@]}" "${docker_files[@]}"
  else
    hadolint "${docker_files[@]}"
  fi
else
  echo "No Docker/Container files found."
fi

echo "Done."
