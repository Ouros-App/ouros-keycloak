#!/usr/bin/env bash
set -Eeuo pipefail

KCADM="/opt/keycloak/bin/kcadm.sh"
REALM="${KC_IAC_REALM:-ouros}"
RESOURCE_DIR="${KC_IAC_RESOURCE_DIR:-/opt/keycloak/iac/resources}"

csv_lookup_id() {
  local endpoint="$1"
  local field="$2"
  local value="$3"

  "${KCADM}" get "${endpoint}" -r "${REALM}" --fields id,"${field}" --format csv --noquotes \
    | awk -F, -v expected="${value}" 'NR > 1 && $2 == expected { print $1; exit }'
}

reconcile_resource_client() {
  local config_file="$1"

  unset CLIENT_ID AUDIENCE SCOPE_NAME MAPPER_NAME
  # shellcheck disable=SC1090
  source "${config_file}"

  : "${CLIENT_ID:?CLIENT_ID is required in ${config_file}}"
  : "${AUDIENCE:=${CLIENT_ID}}"
  : "${SCOPE_NAME:=${CLIENT_ID}-audience}"
  : "${MAPPER_NAME:=${SCOPE_NAME}}"

  echo "[keycloak-iac] reconciling resource client ${CLIENT_ID}"

  local client_uuid
  client_uuid="$(csv_lookup_id clients clientId "${CLIENT_ID}")"

  if [[ -z "${client_uuid}" ]]; then
    "${KCADM}" create clients -r "${REALM}" \
      -s "clientId=${CLIENT_ID}" \
      -s "name=${CLIENT_ID}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=true \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s implicitFlowEnabled=false \
      -s serviceAccountsEnabled=false \
      -s authorizationServicesEnabled=false >/dev/null
    client_uuid="$(csv_lookup_id clients clientId "${CLIENT_ID}")"
    echo "[keycloak-iac] created client ${CLIENT_ID}"
  else
    "${KCADM}" update "clients/${client_uuid}" -r "${REALM}" \
      -s "name=${CLIENT_ID}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=true \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s implicitFlowEnabled=false \
      -s serviceAccountsEnabled=false \
      -s authorizationServicesEnabled=false >/dev/null
    echo "[keycloak-iac] updated client ${CLIENT_ID}"
  fi

  if [[ -z "${client_uuid}" ]]; then
    echo "[keycloak-iac] failed to resolve client UUID for ${CLIENT_ID}" >&2
    return 1
  fi

  local scope_uuid
  scope_uuid="$(csv_lookup_id client-scopes name "${SCOPE_NAME}")"

  if [[ -z "${scope_uuid}" ]]; then
    "${KCADM}" create client-scopes -r "${REALM}" \
      -s "name=${SCOPE_NAME}" \
      -s protocol=openid-connect >/dev/null
    scope_uuid="$(csv_lookup_id client-scopes name "${SCOPE_NAME}")"
    echo "[keycloak-iac] created client scope ${SCOPE_NAME}"
  fi

  if [[ -z "${scope_uuid}" ]]; then
    echo "[keycloak-iac] failed to resolve client scope UUID for ${SCOPE_NAME}" >&2
    return 1
  fi

  local mapper_uuid
  mapper_uuid="$(${KCADM} get "client-scopes/${scope_uuid}/protocol-mappers/models" -r "${REALM}" \
    --fields id,name --format csv --noquotes \
    | awk -F, -v expected="${MAPPER_NAME}" 'NR > 1 && $2 == expected { print $1; exit }')"

  if [[ -z "${mapper_uuid}" ]]; then
    "${KCADM}" create "client-scopes/${scope_uuid}/protocol-mappers/models" -r "${REALM}" \
      -s "name=${MAPPER_NAME}" \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-audience-mapper \
      -s "config.\"included.client.audience\"=\"${AUDIENCE}\"" \
      -s 'config."id.token.claim"="false"' \
      -s 'config."access.token.claim"="true"' \
      -s 'config."lightweight.claim"="false"' \
      -s 'config."introspection.token.claim"="true"' >/dev/null
    echo "[keycloak-iac] created audience mapper ${MAPPER_NAME}"
  else
    "${KCADM}" update "client-scopes/${scope_uuid}/protocol-mappers/models/${mapper_uuid}" -r "${REALM}" \
      -s "name=${MAPPER_NAME}" \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-audience-mapper \
      -s "config.\"included.client.audience\"=\"${AUDIENCE}\"" \
      -s 'config."id.token.claim"="false"' \
      -s 'config."access.token.claim"="true"' \
      -s 'config."lightweight.claim"="false"' \
      -s 'config."introspection.token.claim"="true"' >/dev/null
    echo "[keycloak-iac] updated audience mapper ${MAPPER_NAME}"
  fi

  # PUT is idempotent: if the scope is already attached this remains a no-op.
  "${KCADM}" update "clients/${client_uuid}/default-client-scopes/${scope_uuid}" -r "${REALM}" >/dev/null
  echo "[keycloak-iac] attached ${SCOPE_NAME} to ${CLIENT_ID} as a default scope"
}

shopt -s nullglob
resource_files=("${RESOURCE_DIR}"/*.conf)

if (( ${#resource_files[@]} == 0 )); then
  echo "[keycloak-iac] no managed resource clients found in ${RESOURCE_DIR}"
  exit 0
fi

for config_file in "${resource_files[@]}"; do
  reconcile_resource_client "${config_file}"
done
