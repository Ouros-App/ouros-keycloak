#!/usr/bin/env bash
set -Eeuo pipefail

KCADM="/opt/keycloak/bin/kcadm.sh"
REALM="${KC_IAC_REALM:-ouros}"
CONFIG_FILE="${KC_IAC_USER_STORAGE_FILE:-/opt/keycloak/iac/user-storage/ouros-auth-service.conf}"
PROVIDER_TYPE="org.keycloak.storage.UserStorageProvider"

kcadm_run() {
  local output status
  set +e
  output="$("${KCADM}" "$@" 2>&1)"
  status=$?
  set -e
  if (( status != 0 )); then
    echo "[keycloak-iac] kcadm failed (${status}): kcadm.sh $*" >&2
    [[ -z "${output}" ]] || printf '%s\n' "${output}" >&2
    return "${status}"
  fi
  printf '%s' "${output}"
}

config_get() {
  local file="$1"
  local key="$2"
  local default_value="${3:-}"
  local line
  line="$(grep -E "^${key}=\".*\"$" "${file}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    printf '%s' "${default_value}"
    return
  fi
  line="${line#*=\"}"
  line="${line%\"}"
  printf '%s' "${line}"
}

csv_value() {
  local raw="$1"
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" == "value" || "${line}" == "id" ]] && continue
    printf '%s' "${line}"
    return 0
  done <<< "${raw}"
}

csv_id_for_name() {
  local raw="$1"
  local expected="$2"
  local first second
  while IFS=',' read -r first second; do
    first="${first%$'\r'}"
    second="${second%$'\r'}"
    [[ "${first}" == "id" ]] && continue
    if [[ "${second}" == "${expected}" ]]; then
      printf '%s' "${first}"
      return 0
    fi
  done <<< "${raw}"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

[[ -f "${CONFIG_FILE}" ]] || {
  echo "[keycloak-iac] user-storage config not found: ${CONFIG_FILE}" >&2
  exit 1
}

name="$(config_get "${CONFIG_FILE}" NAME)"
provider_id="$(config_get "${CONFIG_FILE}" PROVIDER_ID)"
auth_service_url="$(config_get "${CONFIG_FILE}" AUTH_SERVICE_URL)"
service_client_id="$(config_get "${CONFIG_FILE}" SERVICE_CLIENT_ID)"
token_url="$(config_get "${CONFIG_FILE}" TOKEN_URL)"
priority="$(config_get "${CONFIG_FILE}" PRIORITY 0)"
cache_policy="$(config_get "${CONFIG_FILE}" CACHE_POLICY NO_CACHE)"

for required in name provider_id auth_service_url service_client_id token_url; do
  [[ -n "${!required}" ]] || {
    echo "[keycloak-iac] missing ${required} in ${CONFIG_FILE}" >&2
    exit 1
  }
done

client_csv="$(kcadm_run get clients -r "${REALM}" -q "clientId=${service_client_id}" --fields id,clientId --format csv --noquotes)"
service_client_uuid="$(csv_id_for_name "${client_csv}" "${service_client_id}")"
[[ -n "${service_client_uuid}" ]] || {
  echo "[keycloak-iac] service client ${service_client_id} does not exist" >&2
  exit 1
}

secret_csv="$(kcadm_run get "clients/${service_client_uuid}/client-secret" -r "${REALM}" --fields value --format csv --noquotes)"
service_client_secret="$(csv_value "${secret_csv}")"
[[ -n "${service_client_secret}" ]] || {
  echo "[keycloak-iac] service client secret is missing for ${service_client_id}" >&2
  exit 1
}

realm_csv="$(kcadm_run get "realms/${REALM}" --fields id --format csv --noquotes)"
realm_id="$(csv_value "${realm_csv}")"
[[ -n "${realm_id}" ]] || {
  echo "[keycloak-iac] could not resolve realm id for ${REALM}" >&2
  exit 1
}

component_csv="$(kcadm_run get components -r "${REALM}" -q "parent=${realm_id}" -q "type=${PROVIDER_TYPE}" -q "name=${name}" --fields id,name --format csv --noquotes)"
component_id="$(csv_id_for_name "${component_csv}" "${name}")"

component_file="/tmp/keycloak-iac/ouros-user-storage-component.json"
umask 077

cleanup_component_file() {
  rm -f "${component_file}"
  unset service_client_secret || true
}
trap cleanup_component_file EXIT

cat > "${component_file}" <<JSON
{
  "name": "$(json_escape "${name}")",
  "providerId": "$(json_escape "${provider_id}")",
  "providerType": "${PROVIDER_TYPE}",
  "parentId": "$(json_escape "${realm_id}")",
  "config": {
    "enabled": ["true"],
    "priority": ["$(json_escape "${priority}")"],
    "cachePolicy": ["$(json_escape "${cache_policy}")"],
    "importEnabled": ["false"],
    "authServiceUrl": ["$(json_escape "${auth_service_url}")"],
    "tokenUrl": ["$(json_escape "${token_url}")"],
    "serviceClientId": ["$(json_escape "${service_client_id}")"],
    "serviceClientSecret": ["$(json_escape "${service_client_secret}")"]
  }
}
JSON

if [[ -z "${component_id}" ]]; then
  kcadm_run create components -r "${REALM}" -f "${component_file}" >/dev/null
  echo "[keycloak-iac] created user-storage provider ${name}"
else
  kcadm_run update "components/${component_id}" -r "${REALM}" -f "${component_file}" >/dev/null
  echo "[keycloak-iac] updated user-storage provider ${name}"
fi

cleanup_component_file
trap - EXIT

echo "[keycloak-iac] user-storage provider ${name} reconciled"
