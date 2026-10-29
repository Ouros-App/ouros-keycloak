#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "[user-storage-validate] ERROR: $*" >&2
  exit 1
}

config_get() {
  local file="$1"
  local key="$2"
  local line
  line="$(grep -E "^${key}=\".*\"$" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  line="${line#*=\"}"
  line="${line%\"}"
  printf '%s' "${line}"
}

validate_config() {
  local file="$1"
  local client_dir="$2"
  local name provider_id auth_url client_id token_url priority cache_policy

  [[ -f "${file}" ]] || fail "missing config ${file}"
  if grep -Eq '^SERVICE_CLIENT_SECRET=' "${file}"; then
    fail "${file}: service secrets must be generated and injected by IaC"
  fi

  name="$(config_get "${file}" NAME)"
  provider_id="$(config_get "${file}" PROVIDER_ID)"
  auth_url="$(config_get "${file}" AUTH_SERVICE_URL)"
  client_id="$(config_get "${file}" SERVICE_CLIENT_ID)"
  token_url="$(config_get "${file}" TOKEN_URL)"
  priority="$(config_get "${file}" PRIORITY)"
  cache_policy="$(config_get "${file}" CACHE_POLICY)"

  [[ "${name}" == "ouros-auth-service" ]] || fail "${file}: invalid NAME"
  [[ "${provider_id}" == "ouros-auth-service" ]] || fail "${file}: invalid PROVIDER_ID"
  [[ "${auth_url}" =~ ^https?://[^[:space:]]+$ ]] || fail "${file}: invalid AUTH_SERVICE_URL"
  [[ "${token_url}" =~ ^https?://[^[:space:]]+$ ]] || fail "${file}: invalid TOKEN_URL"
  [[ "${client_id}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "${file}: invalid SERVICE_CLIENT_ID"
  [[ "${priority}" =~ ^[0-9]+$ ]] || fail "${file}: PRIORITY must be numeric"
  [[ "${cache_policy}" == "NO_CACHE" ]] || fail "${file}: CACHE_POLICY must be NO_CACHE"

  grep -Rqs "^CLIENT_ID=\"${client_id}\"$" "${client_dir}" \
    || fail "${file}: managed service client ${client_id} not found in ${client_dir}"
}

validate_config "iac/user-storage/ouros-auth-service.conf" "iac/resources"
validate_config "iac/test-fixtures/user-storage/ouros-auth-service.conf" "iac/test-fixtures"

grep -qx 'app.ouros.keycloak.storage.OurosUserStorageProviderFactory' \
  providers/ouros-user-storage/src/main/resources/META-INF/services/org.keycloak.storage.UserStorageProviderFactory \
  || fail "UserStorageProviderFactory service-loader registration is missing"

echo "[user-storage-validate] User Storage configuration is valid"
