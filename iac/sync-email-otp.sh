#!/usr/bin/env bash
set -Eeuo pipefail

KCADM="/opt/keycloak/bin/kcadm.sh"
REALM="${KC_IAC_REALM:-ouros}"
FLOW_ALIAS="ouros-browser-email-otp"
FALLBACK_FLOW_ALIAS="${OUROS_EMAIL_OTP_FALLBACK_BROWSER_FLOW:-browser}"
ENABLED="${OUROS_EMAIL_OTP_ENABLED:-false}"

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

flow_exists() {
  local alias="$1"
  kcadm_run get authentication/flows -r "${REALM}" --fields alias --format csv --noquotes \
    | grep -Fxq "${alias}"
}

if [[ "${ENABLED}" != "true" && "${ENABLED}" != "false" ]]; then
  echo "[keycloak-iac] OUROS_EMAIL_OTP_ENABLED must be true or false" >&2
  exit 1
fi

if [[ "${ENABLED}" != "true" ]]; then
  current_browser_flow="$(kcadm_run get "realms/${REALM}" --fields browserFlow --format csv --noquotes)"
  if [[ "${current_browser_flow}" == "${FLOW_ALIAS}" ]]; then
    if ! flow_exists "${FALLBACK_FLOW_ALIAS}"; then
      echo "[keycloak-iac] fallback browser flow ${FALLBACK_FLOW_ALIAS} does not exist" >&2
      exit 1
    fi
    kcadm_run update "realms/${REALM}" -s "browserFlow=${FALLBACK_FLOW_ALIAS}" >/dev/null
    echo "[keycloak-iac] email OTP disabled; restored browser flow ${FALLBACK_FLOW_ALIAS}"
  else
    echo "[keycloak-iac] email OTP disabled; browser flow already uses ${current_browser_flow}"
  fi
  exit 0
fi

if [[ -z "${OUROS_SMTP_HOST:-}" ]]; then
  echo "[keycloak-iac] OUROS_EMAIL_OTP_ENABLED=true requires OUROS_SMTP_HOST" >&2
  exit 1
fi

if ! flow_exists "${FLOW_ALIAS}"; then
  kcadm_run create authentication/flows -r "${REALM}" \
    -s "alias=${FLOW_ALIAS}" \
    -s "description=Ouros browser login with password and email OTP" \
    -s providerId=basic-flow \
    -s topLevel=true \
    -s builtIn=false >/dev/null
  echo "[keycloak-iac] created authentication flow ${FLOW_ALIAS}"
fi

ensure_execution() {
  local provider="$1"
  local requirement="$2"
  local rows execution_id current_requirement current_priority payload_file

  read_execution() {
    rows="$(kcadm_run get "authentication/flows/${FLOW_ALIAS}/executions" -r "${REALM}" \
      --fields id,providerId,requirement,priority --format csv --noquotes)"

    execution_id=""
    current_requirement=""
    current_priority=""
    while IFS=',' read -r id provider_id req priority; do
      if [[ "${provider_id}" == "${provider}" ]]; then
        execution_id="${id}"
        current_requirement="${req}"
        current_priority="${priority}"
        break
      fi
    done <<< "${rows}"
  }

  read_execution

  if [[ -z "${execution_id}" ]]; then
    kcadm_run create "authentication/flows/${FLOW_ALIAS}/executions/execution" \
      -r "${REALM}" -s "provider=${provider}" >/dev/null
    echo "[keycloak-iac] added ${provider} to ${FLOW_ALIAS}"
    read_execution
  fi

  if [[ -z "${execution_id}" || -z "${current_priority}" ]]; then
    echo "[keycloak-iac] could not resolve execution metadata for ${provider}" >&2
    exit 1
  fi

  if [[ "${current_requirement}" != "${requirement}" ]]; then
    payload_file="$(mktemp)"
    printf '{"id":"%s","requirement":"%s","priority":%s}\n' \
      "${execution_id}" "${requirement}" "${current_priority}" > "${payload_file}"

    if ! kcadm_run update "authentication/flows/${FLOW_ALIAS}/executions" -r "${REALM}" \
      -f "${payload_file}" >/dev/null; then
      rm -f "${payload_file}"
      return 1
    fi
    rm -f "${payload_file}"
    echo "[keycloak-iac] set ${provider} requirement to ${requirement}"
  fi
}

ensure_execution "auth-username-password-form" "REQUIRED"
ensure_execution "ouros-email-otp" "REQUIRED"

kcadm_run update "realms/${REALM}" -s "browserFlow=${FLOW_ALIAS}" >/dev/null

echo "[keycloak-iac] bound realm ${REALM} browser flow to ${FLOW_ALIAS}"
