#!/usr/bin/env bash
set -Eeuo pipefail

KCADM="/opt/keycloak/bin/kcadm.sh"
REALM="${KC_IAC_REALM:-ouros}"
RESOURCE_DIR="${KC_IAC_RESOURCE_DIR:-/opt/keycloak/iac/resources}"
IDENTITY_SCOPE_NAME="${KC_IAC_IDENTITY_SCOPE_NAME:-ouros-identity}"

kcadm_run() {
  local output status

  set +e
  output="$("${KCADM}" "$@" 2>&1)"
  status=$?
  set -e

  if (( status != 0 )); then
    echo "[keycloak-iac] kcadm failed (${status}): kcadm.sh $*" >&2
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}" >&2
    else
      echo "[keycloak-iac] kcadm produced no diagnostic output" >&2
    fi
    return "${status}"
  fi

  printf '%s' "${output}"
}

config_get() {
  local file="$1"
  local key="$2"
  local default_value="${3:-}"
  local line value=""
  local found=false

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^${key}=\"([^\"]*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
      found=true
    fi
  done < "${file}"

  if [[ "${found}" == true ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${default_value}"
  fi
}

csv_id_for_value() {
  local output="$1"
  local expected="$2"
  local first second

  while IFS=',' read -r first second; do
    first="${first%$'\r'}"
    second="${second%$'\r'}"

    # kcadm may emit a header such as id,clientId. Never treat the column
    # names as data, while still allowing a legitimate value such as CLIENT_ID=id.
    if [[ "${first}" == "id" ]]; then
      continue
    fi

    if [[ "${second}" == "${expected}" ]]; then
      printf '%s' "${first}"
      return 0
    fi
    if [[ "${first}" == "${expected}" ]]; then
      printf '%s' "${second}"
      return 0
    fi
  done <<< "${output}"

  return 0
}

csv_lookup_id() {
  local endpoint="$1"
  local field="$2"
  local value="$3"
  local output

  output="$(kcadm_run get "${endpoint}" -r "${REALM}" --fields id,"${field}" --format csv --noquotes)"
  csv_id_for_value "${output}" "${value}"
}

json_array_from_pipe() {
  local raw="$1"
  local item escaped
  local first=true
  local -a items=()

  if [[ -z "${raw}" ]]; then
    printf '[]'
    return
  fi

  IFS='|' read -r -a items <<< "${raw}"
  printf '['
  for item in "${items[@]}"; do
    escaped="${item//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if [[ "${first}" == false ]]; then
      printf ','
    fi
    printf '"%s"' "${escaped}"
    first=false
  done
  printf ']'
}

upsert_base_client() {
  local client_id="$1"
  local public_client="$2"
  local standard_flow="$3"
  local redirect_uris_json="$4"
  local web_origins_json="$5"
  local pkce="$6"
  local service_accounts="$7"

  local client_uuid
  client_uuid="$(csv_lookup_id clients clientId "${client_id}")"

  local -a settings=(
    -s "name=${client_id}"
    -s enabled=true
    -s protocol=openid-connect
    -s "publicClient=${public_client}"
    -s bearerOnly=false
    -s "standardFlowEnabled=${standard_flow}"
    -s directAccessGrantsEnabled=false
    -s implicitFlowEnabled=false
    -s "serviceAccountsEnabled=${service_accounts}"
    -s authorizationServicesEnabled=false
    -s consentRequired=false
    -s alwaysDisplayInConsole=false
    -s "redirectUris=${redirect_uris_json}"
    -s "webOrigins=${web_origins_json}"
  )

  if [[ "${pkce}" == true ]]; then
    settings+=( -s 'attributes={"pkce.code.challenge.method":"S256"}' )
  else
    settings+=( -s 'attributes={}' )
  fi

  if [[ "${service_accounts}" == true ]]; then
    settings+=( -s clientAuthenticatorType=client-secret )
  fi

  if [[ -z "${client_uuid}" ]]; then
    kcadm_run create clients -r "${REALM}" -s "clientId=${client_id}" "${settings[@]}" >/dev/null
    client_uuid="$(csv_lookup_id clients clientId "${client_id}")"
    echo "[keycloak-iac] created client ${client_id}" >&2
  else
    kcadm_run update "clients/${client_uuid}" -r "${REALM}" "${settings[@]}" >/dev/null
    echo "[keycloak-iac] updated client ${client_id}" >&2
  fi

  if [[ -z "${client_uuid}" ]]; then
    echo "[keycloak-iac] failed to resolve client UUID for ${client_id}" >&2
    return 1
  fi

  printf '%s' "${client_uuid}"
}

ensure_audience_scope() {
  local audience="$1"
  local scope_name="$2"
  local mapper_name="$3"

  local scope_uuid mapper_uuid mapper_output
  scope_uuid="$(csv_lookup_id client-scopes name "${scope_name}")"

  if [[ -z "${scope_uuid}" ]]; then
    kcadm_run create client-scopes -r "${REALM}" \
      -s "name=${scope_name}" \
      -s protocol=openid-connect >/dev/null
    scope_uuid="$(csv_lookup_id client-scopes name "${scope_name}")"
    echo "[keycloak-iac] created client scope ${scope_name}" >&2
  else
    kcadm_run update "client-scopes/${scope_uuid}" -r "${REALM}" \
      -s "name=${scope_name}" \
      -s protocol=openid-connect >/dev/null
    echo "[keycloak-iac] updated client scope ${scope_name}" >&2
  fi

  if [[ -z "${scope_uuid}" ]]; then
    echo "[keycloak-iac] failed to resolve client scope UUID for ${scope_name}" >&2
    return 1
  fi

  mapper_output="$(kcadm_run get "client-scopes/${scope_uuid}/protocol-mappers/models" -r "${REALM}" \
    --fields id,name --format csv --noquotes)"
  mapper_uuid="$(csv_id_for_value "${mapper_output}" "${mapper_name}")"

  local -a mapper_settings=(
    -s "name=${mapper_name}"
    -s protocol=openid-connect
    -s protocolMapper=oidc-audience-mapper
    -s "config.\"included.client.audience\"=\"${audience}\""
    -s 'config."id.token.claim"="false"'
    -s 'config."access.token.claim"="true"'
    -s 'config."lightweight.claim"="false"'
    -s 'config."introspection.token.claim"="true"'
  )

  if [[ -z "${mapper_uuid}" ]]; then
    kcadm_run create "client-scopes/${scope_uuid}/protocol-mappers/models" -r "${REALM}" "${mapper_settings[@]}" >/dev/null
    echo "[keycloak-iac] created audience mapper ${mapper_name}" >&2
  else
    kcadm_run update "client-scopes/${scope_uuid}/protocol-mappers/models/${mapper_uuid}" -r "${REALM}" "${mapper_settings[@]}" >/dev/null
    echo "[keycloak-iac] updated audience mapper ${mapper_name}" >&2
  fi

  printf '%s' "${scope_uuid}"
}

ensure_user_attribute_mapper() {
  local scope_uuid="$1"
  local attribute_name="$2"
  local claim_name="$3"
  local json_type="$4"
  local mapper_name="ouros-${claim_name}"
  local mapper_output mapper_uuid

  mapper_output="$(kcadm_run get "client-scopes/${scope_uuid}/protocol-mappers/models" -r "${REALM}"     --fields id,name --format csv --noquotes)"
  mapper_uuid="$(csv_id_for_value "${mapper_output}" "${mapper_name}")"

  local -a mapper_settings=(
    -s "name=${mapper_name}"
    -s protocol=openid-connect
    -s protocolMapper=oidc-usermodel-attribute-mapper
    -s "config.\"user.attribute\"=\"${attribute_name}\""
    -s "config.\"claim.name\"=\"${claim_name}\""
    -s "config.\"jsonType.label\"=\"${json_type}\""
    -s 'config."id.token.claim"="false"'
    -s 'config."access.token.claim"="true"'
    -s 'config."userinfo.token.claim"="true"'
    -s 'config."introspection.token.claim"="true"'
    -s 'config."multivalued"="false"'
    -s 'config."aggregate.attrs"="false"'
  )

  if [[ -z "${mapper_uuid}" ]]; then
    kcadm_run create "client-scopes/${scope_uuid}/protocol-mappers/models" -r "${REALM}"       "${mapper_settings[@]}" >/dev/null
    echo "[keycloak-iac] created identity mapper ${mapper_name}" >&2
  else
    kcadm_run update "client-scopes/${scope_uuid}/protocol-mappers/models/${mapper_uuid}" -r "${REALM}"       "${mapper_settings[@]}" >/dev/null
    echo "[keycloak-iac] updated identity mapper ${mapper_name}" >&2
  fi
}

ensure_identity_scope() {
  local scope_uuid
  scope_uuid="$(csv_lookup_id client-scopes name "${IDENTITY_SCOPE_NAME}")"

  if [[ -z "${scope_uuid}" ]]; then
    kcadm_run create client-scopes -r "${REALM}"       -s "name=${IDENTITY_SCOPE_NAME}"       -s protocol=openid-connect >/dev/null
    scope_uuid="$(csv_lookup_id client-scopes name "${IDENTITY_SCOPE_NAME}")"
    echo "[keycloak-iac] created identity scope ${IDENTITY_SCOPE_NAME}" >&2
  else
    kcadm_run update "client-scopes/${scope_uuid}" -r "${REALM}"       -s "name=${IDENTITY_SCOPE_NAME}"       -s protocol=openid-connect >/dev/null
    echo "[keycloak-iac] updated identity scope ${IDENTITY_SCOPE_NAME}" >&2
  fi

  [[ -n "${scope_uuid}" ]] || {
    echo "[keycloak-iac] failed to resolve identity scope ${IDENTITY_SCOPE_NAME}" >&2
    return 1
  }

  ensure_user_attribute_mapper "${scope_uuid}" database_id database_id long
  ensure_user_attribute_mapper "${scope_uuid}" account_type account_type String
  ensure_user_attribute_mapper "${scope_uuid}" farm_id farm_id long
  ensure_user_attribute_mapper "${scope_uuid}" enterprise_id enterprise_id long
  ensure_user_attribute_mapper "${scope_uuid}" first_access first_access boolean

  printf '%s' "${scope_uuid}"
}

attach_default_scope() {
  local client_uuid="$1"
  local scope_uuid="$2"
  # This sub-resource supports PUT but not GET, so kcadm must skip its usual
  # read-before-update merge behavior.
  kcadm_run update "clients/${client_uuid}/default-client-scopes/${scope_uuid}" -r "${REALM}" -n >/dev/null
}

scope_name_for_audience() {
  local target_audience="$1"
  local file client_type client_id audience scope_name

  for file in "${resource_files[@]}"; do
    client_type="$(config_get "${file}" CLIENT_TYPE)"
    [[ "${client_type}" == microservice ]] || continue

    client_id="$(config_get "${file}" CLIENT_ID)"
    audience="$(config_get "${file}" AUDIENCE "${client_id}")"
    if [[ "${audience}" == "${target_audience}" ]]; then
      scope_name="$(config_get "${file}" SCOPE_NAME "${client_id}-audience")"
      printf '%s' "${scope_name}"
      return 0
    fi
  done

  return 1
}

attach_managed_audiences() {
  local client_uuid="$1"
  local client_id="$2"
  local audiences="$3"
  local audience scope_name scope_uuid
  local -a audience_items=()

  [[ -n "${audiences}" ]] || return 0

  IFS='|' read -r -a audience_items <<< "${audiences}"
  for audience in "${audience_items[@]}"; do
    if ! scope_name="$(scope_name_for_audience "${audience}")"; then
      echo "[keycloak-iac] ${client_id} references unmanaged audience ${audience}" >&2
      return 1
    fi

    scope_uuid="$(csv_lookup_id client-scopes name "${scope_name}")"
    if [[ -z "${scope_uuid}" ]]; then
      echo "[keycloak-iac] audience scope ${scope_name} for ${audience} does not exist" >&2
      return 1
    fi

    attach_default_scope "${client_uuid}" "${scope_uuid}"
    echo "[keycloak-iac] attached audience ${audience} to ${client_id}"
  done
}

reconcile_microservice() {
  local file="$1"
  local client_id audience scope_name mapper_name client_uuid scope_uuid

  client_id="$(config_get "${file}" CLIENT_ID)"
  audience="$(config_get "${file}" AUDIENCE "${client_id}")"
  scope_name="$(config_get "${file}" SCOPE_NAME "${client_id}-audience")"
  mapper_name="$(config_get "${file}" MAPPER_NAME "${scope_name}")"

  [[ -n "${client_id}" ]] || { echo "[keycloak-iac] CLIENT_ID missing in ${file}" >&2; return 1; }

  echo "[keycloak-iac] reconciling microservice ${client_id}"
  client_uuid="$(upsert_base_client "${client_id}" true false '[]' '[]' false false)"
  scope_uuid="$(ensure_audience_scope "${audience}" "${scope_name}" "${mapper_name}")"
  attach_default_scope "${client_uuid}" "${scope_uuid}"
  echo "[keycloak-iac] microservice ${client_id} ready with audience ${audience}"
}

reconcile_application() {
  local file="$1"
  local client_type client_id redirect_uris web_origins audiences
  local redirect_json web_origins_json client_uuid

  client_type="$(config_get "${file}" CLIENT_TYPE)"
  client_id="$(config_get "${file}" CLIENT_ID)"
  redirect_uris="$(config_get "${file}" REDIRECT_URIS)"
  web_origins="$(config_get "${file}" WEB_ORIGINS)"
  audiences="$(config_get "${file}" AUDIENCES)"

  [[ -n "${client_id}" ]] || { echo "[keycloak-iac] CLIENT_ID missing in ${file}" >&2; return 1; }
  [[ -n "${redirect_uris}" ]] || { echo "[keycloak-iac] REDIRECT_URIS missing for ${client_id}" >&2; return 1; }

  if [[ "${client_type}" == web && -z "${web_origins}" ]]; then
    echo "[keycloak-iac] WEB_ORIGINS missing for web client ${client_id}" >&2
    return 1
  fi

  redirect_json="$(json_array_from_pipe "${redirect_uris}")"
  web_origins_json="$(json_array_from_pipe "${web_origins}")"

  echo "[keycloak-iac] reconciling ${client_type} client ${client_id}"
  client_uuid="$(upsert_base_client "${client_id}" true true "${redirect_json}" "${web_origins_json}" true false)"
  attach_managed_audiences "${client_uuid}" "${client_id}" "${audiences}"
  attach_default_scope "${client_uuid}" "${identity_scope_uuid}"

  echo "[keycloak-iac] ${client_type} client ${client_id} ready with Authorization Code + PKCE S256 and identity claims"
}

reconcile_service() {
  local file="$1"
  local client_id audiences client_uuid

  client_id="$(config_get "${file}" CLIENT_ID)"
  audiences="$(config_get "${file}" AUDIENCES)"

  [[ -n "${client_id}" ]] || { echo "[keycloak-iac] CLIENT_ID missing in ${file}" >&2; return 1; }

  echo "[keycloak-iac] reconciling service client ${client_id}"
  client_uuid="$(upsert_base_client "${client_id}" false false '[]' '[]' false true)"
  attach_managed_audiences "${client_uuid}" "${client_id}" "${audiences}"

  echo "[keycloak-iac] service client ${client_id} ready for Client Credentials"
}

shopt -s nullglob
resource_files=("${RESOURCE_DIR}"/*.conf)

if (( ${#resource_files[@]} == 0 )); then
  echo "[keycloak-iac] no managed clients found in ${RESOURCE_DIR}"
  exit 0
fi

identity_scope_uuid="$(ensure_identity_scope)"

# First create every resource server and its audience scope. Applications and
# service identities are reconciled afterwards so AUDIENCES references are
# order-independent.
for config_file in "${resource_files[@]}"; do
  client_type="$(config_get "${config_file}" CLIENT_TYPE)"
  case "${client_type}" in
    microservice) reconcile_microservice "${config_file}" ;;
    mobile|web|service) ;;
    *) echo "[keycloak-iac] unsupported CLIENT_TYPE '${client_type}' in ${config_file}" >&2; exit 1 ;;
  esac
done

for config_file in "${resource_files[@]}"; do
  client_type="$(config_get "${config_file}" CLIENT_TYPE)"
  case "${client_type}" in
    mobile|web) reconcile_application "${config_file}" ;;
    service) reconcile_service "${config_file}" ;;
  esac
done
