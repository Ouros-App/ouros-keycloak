#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "[iac-validate] ERROR: $*" >&2
  exit 1
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

validate_pipe_list() {
  local file="$1"
  local key="$2"
  local value="$3"

  [[ -z "${value}" ]] && return 0
  [[ "${value}" != '|'* ]] || fail "${file}: ${key} cannot start with |"
  [[ "${value}" != *'|' ]] || fail "${file}: ${key} cannot end with |"
  [[ "${value}" != *'||'* ]] || fail "${file}: ${key} contains an empty item"
}

validate_redirects() {
  local file="$1"
  local client_type="$2"
  local raw="$3"
  local item
  local -a items=()

  [[ -n "${raw}" ]] || return 0
  IFS='|' read -r -a items <<< "${raw}"
  for item in "${items[@]}"; do
    case "${client_type}" in
      web)
        [[ "${item}" == https://* || "${item}" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?([/?#].*)?$ ]] \
          || fail "${file}: web REDIRECT_URIS must use HTTPS (localhost HTTP is allowed)"
        ;;
      mobile)
        [[ "${item}" =~ ^[A-Za-z][A-Za-z0-9+.-]*:/ ]] \
          || fail "${file}: mobile REDIRECT_URIS must use an absolute URI/custom scheme"
        ;;
    esac
  done
}

validate_web_origins() {
  local file="$1"
  local raw="$2"
  local item
  local -a items=()

  [[ -n "${raw}" ]] || return 0
  IFS='|' read -r -a items <<< "${raw}"
  for item in "${items[@]}"; do
    [[ "${item}" != *'*'* ]] || fail "${file}: WEB_ORIGINS cannot contain wildcards"
    [[ "${item}" == https://* || "${item}" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?$ ]] \
      || fail "${file}: WEB_ORIGINS must use HTTPS (localhost HTTP is allowed)"
  done
}

validate_file_shape() {
  local file="$1"
  local line key
  local -A seen=()

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

    if [[ ! "${line}" =~ ^([A-Z_]+)=\"[^\"]*\"$ ]]; then
      fail "${file}: only KEY=\"value\" declarations, comments and blank lines are allowed"
    fi

    key="${BASH_REMATCH[1]}"
    case "${key}" in
      CLIENT_TYPE|CLIENT_ID|AUDIENCE|SCOPE_NAME|MAPPER_NAME|REDIRECT_URIS|WEB_ORIGINS|AUDIENCES) ;;
      *) fail "${file}: unsupported key ${key}" ;;
    esac

    [[ -z "${seen[${key}]:-}" ]] || fail "${file}: duplicate key ${key}"
    seen["${key}"]=1
  done < "${file}"
}

validate_group() {
  local directory="$1"
  local pattern="$2"
  local label="$3"
  local require_all_types="${4:-false}"
  local file client_type client_id audience audiences redirect_uris web_origins scope_name mapper_name
  local audience_item required_type
  local -a files=()
  local -a audience_items=()
  local -A client_ids=()
  local -A managed_audiences=()
  local -A scope_names=()
  local -A client_types_seen=()

  while IFS= read -r file; do
    files+=("${file}")
  done < <(find "${directory}" -maxdepth 1 -type f -name "${pattern}" -print | sort)

  (( ${#files[@]} > 0 )) || fail "${label}: no configuration files found"

  for file in "${files[@]}"; do
    validate_file_shape "${file}"

    client_type="$(config_get "${file}" CLIENT_TYPE)"
    client_id="$(config_get "${file}" CLIENT_ID)"
    audience="$(config_get "${file}" AUDIENCE "${client_id}")"
    audiences="$(config_get "${file}" AUDIENCES)"
    redirect_uris="$(config_get "${file}" REDIRECT_URIS)"
    web_origins="$(config_get "${file}" WEB_ORIGINS)"
    scope_name="$(config_get "${file}" SCOPE_NAME)"
    mapper_name="$(config_get "${file}" MAPPER_NAME)"

    [[ "${client_type}" =~ ^(microservice|mobile|web|service|token-exchange|password-broker|password-grant)$ ]] \
      || fail "${file}: CLIENT_TYPE must be microservice, mobile, web, service, token-exchange, password-broker or password-grant"
    client_types_seen["${client_type}"]=1

    [[ "${client_id}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "${file}: invalid CLIENT_ID '${client_id}'"
    [[ -z "${client_ids[${client_id}]:-}" ]] || fail "${label}: duplicate CLIENT_ID ${client_id}"
    client_ids["${client_id}"]="${file}"

    validate_pipe_list "${file}" REDIRECT_URIS "${redirect_uris}"
    validate_pipe_list "${file}" WEB_ORIGINS "${web_origins}"
    validate_pipe_list "${file}" AUDIENCES "${audiences}"
    validate_redirects "${file}" "${client_type}" "${redirect_uris}"

    case "${client_type}" in
      microservice)
        [[ -z "${redirect_uris}" && -z "${web_origins}" && -z "${audiences}" ]] \
          || fail "${file}: microservice clients cannot declare REDIRECT_URIS, WEB_ORIGINS or AUDIENCES"
        [[ "${audience}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "${file}: invalid AUDIENCE '${audience}'"
        [[ -n "${scope_name}" ]] || scope_name="${client_id}-audience"
        [[ -n "${mapper_name}" ]] || mapper_name="${scope_name}"
        [[ -z "${managed_audiences[${audience}]:-}" ]] || fail "${label}: duplicate AUDIENCE ${audience}"
        [[ -z "${scope_names[${scope_name}]:-}" ]] || fail "${label}: duplicate SCOPE_NAME ${scope_name}"
        managed_audiences["${audience}"]="${file}"
        scope_names["${scope_name}"]="${file}"
        ;;
      mobile)
        [[ -n "${redirect_uris}" ]] || fail "${file}: mobile clients require REDIRECT_URIS"
        [[ -z "${web_origins}" ]] || fail "${file}: mobile clients cannot declare WEB_ORIGINS"
        [[ -z "${scope_name}" && -z "${mapper_name}" && "$(config_get "${file}" AUDIENCE)" == "" ]] \
          || fail "${file}: mobile clients cannot declare AUDIENCE, SCOPE_NAME or MAPPER_NAME"
        ;;
      web)
        [[ -n "${redirect_uris}" ]] || fail "${file}: web clients require REDIRECT_URIS"
        [[ -n "${web_origins}" ]] || fail "${file}: web clients require WEB_ORIGINS"
        validate_web_origins "${file}" "${web_origins}"
        [[ -z "${scope_name}" && -z "${mapper_name}" && "$(config_get "${file}" AUDIENCE)" == "" ]] \
          || fail "${file}: web clients cannot declare AUDIENCE, SCOPE_NAME or MAPPER_NAME"
        ;;
      token-exchange)
        [[ -z "${redirect_uris}" && -z "${web_origins}" ]] \
          || fail "${file}: token-exchange clients cannot declare REDIRECT_URIS or WEB_ORIGINS"
        [[ -n "${audiences}" ]] \
          || fail "${file}: token-exchange clients require target AUDIENCES"
        [[ "${audience}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
          || fail "${file}: invalid token-exchange AUDIENCE '${audience}'"
        [[ -n "${scope_name}" ]] || scope_name="${client_id}-audience"
        [[ -n "${mapper_name}" ]] || mapper_name="${scope_name}"
        [[ -z "${managed_audiences[${audience}]:-}" ]] || fail "${label}: duplicate AUDIENCE ${audience}"
        [[ -z "${scope_names[${scope_name}]:-}" ]] || fail "${label}: duplicate SCOPE_NAME ${scope_name}"
        managed_audiences["${audience}"]="${file}"
        scope_names["${scope_name}"]="${file}"
        ;;
      service|password-broker|password-grant)
        [[ -z "${redirect_uris}" && -z "${web_origins}" ]] \
          || fail "${file}: service/password-grant clients cannot declare REDIRECT_URIS or WEB_ORIGINS"
        [[ -z "${scope_name}" && -z "${mapper_name}" && "$(config_get "${file}" AUDIENCE)" == "" ]] \
          || fail "${file}: service/password-grant clients cannot declare AUDIENCE, SCOPE_NAME or MAPPER_NAME"
        ;;
    esac
  done

  for file in "${files[@]}"; do
    client_type="$(config_get "${file}" CLIENT_TYPE)"
    [[ "${client_type}" == mobile || "${client_type}" == web || "${client_type}" == service || "${client_type}" == token-exchange || "${client_type}" == password-broker || "${client_type}" == password-grant ]] || continue

    audiences="$(config_get "${file}" AUDIENCES)"
    [[ -n "${audiences}" ]] || continue

    IFS='|' read -r -a audience_items <<< "${audiences}"
    for audience_item in "${audience_items[@]}"; do
      [[ -n "${managed_audiences[${audience_item}]:-}" ]] \
        || fail "${file}: AUDIENCES references unmanaged microservice audience ${audience_item}"
    done
  done

  if [[ "${require_all_types}" == true ]]; then
    for required_type in microservice mobile web service; do
      [[ -n "${client_types_seen[${required_type}]:-}" ]] \
        || fail "${label}: missing ${required_type} client coverage"
    done
  fi

  echo "[iac-validate] ${label}: ${#files[@]} client declarations valid"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
jq -e '
  .realm == "ouros"
  and .enabled == true
  and .sslRequired == "external"
  and .registrationAllowed == false
  and .resetPasswordAllowed == false
  and .verifyEmail == false
  and .bruteForceProtected == true
' realm/ouros-realm.json >/dev/null \
  || fail "realm/ouros-realm.json must define the hardened ouros realm"

grep -qx 'TYPE=site' discloud.config || fail "discloud.config must use TYPE=site"
grep -qx 'MAIN=Dockerfile' discloud.config || fail "discloud.config must use MAIN=Dockerfile"
grep -qx 'ID=ouros-keycloak' discloud.config || fail "discloud.config must reserve ID=ouros-keycloak"
grep -qx 'VLAN=true' discloud.config || fail "discloud.config must keep VLAN=true for keycloak-db"

grep -q 'keycloak-entrypoint.sh' Dockerfile || fail "Dockerfile must run the IaC-aware entrypoint"

validate_first_party_broker_contract() {
  local broker_file="iac/resources/ms-auth-service-broker.conf"
  local actual expected actual_sorted expected_sorted
  expected="ms-spring-api|ms-telemetry-dashboard-service|ms-ai-server|ms-ai-server-mcp-exchange|ms-mcp-server-ouros-knowledge-codemode"

  [[ -f "${broker_file}" ]] || fail "${broker_file}: official first-party broker declaration is required"
  [[ "$(config_get "${broker_file}" CLIENT_TYPE)" == "password-broker" ]] \
    || fail "${broker_file}: CLIENT_TYPE must remain password-broker"
  [[ "$(config_get "${broker_file}" CLIENT_ID)" == "ms-auth-service-broker" ]] \
    || fail "${broker_file}: CLIENT_ID must remain ms-auth-service-broker"

  actual="$(config_get "${broker_file}" AUDIENCES)"
  actual_sorted="$(tr '|' '\n' <<< "${actual}" | sed '/^$/d' | sort -u | paste -sd'|' -)"
  expected_sorted="$(tr '|' '\n' <<< "${expected}" | sort -u | paste -sd'|' -)"
  [[ "${actual_sorted}" == "${expected_sorted}" ]] \
    || fail "${broker_file}: AUDIENCES must contain the complete Phase 3 first-party resource-server set"
}


validate_debug_console_contract() {
  local debug_file="iac/resources/ms-ai-server-debug.conf"
  local actual expected actual_sorted expected_sorted
  expected="ms-ai-server|ms-ai-server-mcp-exchange"

  [[ -f "${debug_file}" ]] || fail "${debug_file}: official debug client declaration is required"
  [[ "$(config_get "${debug_file}" CLIENT_TYPE)" == "password-grant" ]] \
    || fail "${debug_file}: CLIENT_TYPE must remain password-grant"
  [[ "$(config_get "${debug_file}" CLIENT_ID)" == "ms-ai-server-debug" ]] \
    || fail "${debug_file}: CLIENT_ID must remain ms-ai-server-debug"

  actual="$(config_get "${debug_file}" AUDIENCES)"
  actual_sorted="$(tr '|' '\n' <<< "${actual}" | sed '/^$/d' | sort -u | paste -sd'|' -)"
  expected_sorted="$(tr '|' '\n' <<< "${expected}" | sort -u | paste -sd'|' -)"
  [[ "${actual_sorted}" == "${expected_sorted}" ]] \
    || fail "${debug_file}: AUDIENCES must allow the AI Server and its standard MCP resource"
}

validate_mobile_client_contract() {
  local mobile_file="iac/resources/ouros-mobile.conf"
  local actual expected actual_sorted expected_sorted redirects

  expected="ms-spring-api|ms-ai-server|ms-telemetry-dashboard-service|ms-ai-server-mcp-exchange"

  [[ -f "${mobile_file}" ]] || fail "${mobile_file}: official mobile client declaration is required"
  [[ "$(config_get "${mobile_file}" CLIENT_TYPE)" == "mobile" ]] \
    || fail "${mobile_file}: CLIENT_TYPE must remain mobile"
  [[ "$(config_get "${mobile_file}" CLIENT_ID)" == "ouros-mobile" ]] \
    || fail "${mobile_file}: CLIENT_ID must remain ouros-mobile"

  redirects="$(config_get "${mobile_file}" REDIRECT_URIS)"
  [[ "|${redirects}|" == *"|com.ourosapp.ourosandroidapp:/oauth2redirect|"* ]] \
    || fail "${mobile_file}: exact Android redirect URI is required"
  [[ "|${redirects}|" == *"|http://127.0.0.1:8765/callback|"* ]] \
    || fail "${mobile_file}: exact E2E loopback redirect URI is required"

  actual="$(config_get "${mobile_file}" AUDIENCES)"
  actual_sorted="$(tr '|' '\n' <<< "${actual}" | sed '/^$/d' | sort -u | paste -sd'|' -)"
  expected_sorted="$(tr '|' '\n' <<< "${expected}" | sort -u | paste -sd'|' -)"
  [[ "${actual_sorted}" == "${expected_sorted}" ]] \
    || fail "${mobile_file}: AUDIENCES must contain the complete mobile surface plus the confidential exchange requester"
}

validate_token_exchange_contract() {
  local exchange_file="iac/resources/ms-ai-server-mcp-exchange.conf"

  [[ -f "${exchange_file}" ]] || fail "${exchange_file}: official Midas token-exchange client is required"
  [[ "$(config_get "${exchange_file}" CLIENT_TYPE)" == "token-exchange" ]] \
    || fail "${exchange_file}: CLIENT_TYPE must remain token-exchange"
  [[ "$(config_get "${exchange_file}" CLIENT_ID)" == "ms-ai-server-mcp-exchange" ]] \
    || fail "${exchange_file}: CLIENT_ID must remain ms-ai-server-mcp-exchange"
  [[ "$(config_get "${exchange_file}" AUDIENCE)" == "ms-ai-server-mcp-exchange" ]] \
    || fail "${exchange_file}: requester audience must remain ms-ai-server-mcp-exchange"
  [[ "$(config_get "${exchange_file}" AUDIENCES)" == "ms-mcp-server-ouros-knowledge" ]] \
    || fail "${exchange_file}: target audience must remain the standard Knowledge MCP"
}

validate_group iac/resources '*.conf' production false
validate_token_exchange_contract
validate_first_party_broker_contract
validate_debug_console_contract
validate_mobile_client_contract
validate_group iac/examples '*.conf.example' examples true
validate_group iac/test-fixtures '*.conf' test-fixtures true

echo "[iac-validate] repository configuration is valid"
