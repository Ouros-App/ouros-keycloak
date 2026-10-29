#!/usr/bin/env bash
set -Eeuo pipefail

KCADM="/opt/keycloak/bin/kcadm.sh"
REALM="${KC_IAC_REALM:-ouros}"

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

kcadm_run_sensitive() {
  local output status
  set +e
  output="$("${KCADM}" "$@" 2>&1)"
  status=$?
  set -e
  if (( status != 0 )); then
    echo "[keycloak-iac] sensitive kcadm operation failed (${status}); command arguments were redacted" >&2
    [[ -z "${output}" ]] || printf '%s\n' "${output}" >&2
    return "${status}"
  fi
  printf '%s' "${output}"
}

require_bool() {
  local name="$1"
  local value="$2"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    echo "[keycloak-iac] ${name} must be true or false" >&2
    exit 1
  fi
}

kcadm_run get "realms/${REALM}" >/dev/null

ensure_realm_role() {
  local role_name="$1"
  local description="$2"
  local roles_csv
  roles_csv="$(kcadm_run get roles -r "${REALM}" --fields name --format csv --noquotes)"
  if grep -Fxq "${role_name}" <<< "${roles_csv}"; then
    kcadm_run update "roles/${role_name}" -r "${REALM}" -s "name=${role_name}" -s "description=${description}" >/dev/null
    echo "[keycloak-iac] updated realm role ${role_name}"
  else
    kcadm_run create roles -r "${REALM}" -s "name=${role_name}" -s "description=${description}" >/dev/null
    echo "[keycloak-iac] created realm role ${role_name}"
  fi
}

kcadm_run update "realms/${REALM}" \
  -s enabled=true \
  -s sslRequired=external \
  -s registrationAllowed=false \
  -s loginWithEmailAllowed=true \
  -s duplicateEmailsAllowed=false \
  -s resetPasswordAllowed=false \
  -s editUsernameAllowed=false \
  -s verifyEmail=false \
  -s bruteForceProtected=true >/dev/null

echo "[keycloak-iac] realm ${REALM} security settings reconciled"

smtp_host="${OUROS_SMTP_HOST:-}"
if [[ -n "${smtp_host}" ]]; then
  smtp_port="${OUROS_SMTP_PORT:-587}"
  smtp_from="${OUROS_SMTP_FROM:-no-reply@ouros.local}"
  smtp_from_name="${OUROS_SMTP_FROM_DISPLAY_NAME:-Ouros}"
  smtp_auth="${OUROS_SMTP_AUTH:-false}"
  smtp_starttls="${OUROS_SMTP_STARTTLS:-true}"
  smtp_ssl="${OUROS_SMTP_SSL:-false}"
  smtp_user="${OUROS_SMTP_USER:-}"
  smtp_password="${OUROS_SMTP_PASSWORD:-}"

  require_bool OUROS_SMTP_AUTH "${smtp_auth}"
  require_bool OUROS_SMTP_STARTTLS "${smtp_starttls}"
  require_bool OUROS_SMTP_SSL "${smtp_ssl}"

  if [[ "${smtp_starttls}" == "true" && "${smtp_ssl}" == "true" ]]; then
    echo "[keycloak-iac] OUROS_SMTP_STARTTLS and OUROS_SMTP_SSL cannot both be true" >&2
    exit 1
  fi

  if [[ "${smtp_auth}" == "true" && ( -z "${smtp_user}" || -z "${smtp_password}" ) ]]; then
    echo "[keycloak-iac] authenticated SMTP requires OUROS_SMTP_USER and OUROS_SMTP_PASSWORD" >&2
    exit 1
  fi

  smtp_args=(
    update "realms/${REALM}"
    -s "smtpServer.host=${smtp_host}"
    -s "smtpServer.port=${smtp_port}"
    -s "smtpServer.from=${smtp_from}"
    -s "smtpServer.fromDisplayName=${smtp_from_name}"
    -s "smtpServer.auth=${smtp_auth}"
    -s "smtpServer.starttls=${smtp_starttls}"
    -s "smtpServer.ssl=${smtp_ssl}"
  )

  if [[ "${smtp_auth}" == "true" ]]; then
    smtp_args+=(
      -s "smtpServer.user=${smtp_user}"
      -s "smtpServer.password=${smtp_password}"
    )
  else
    smtp_args+=(
      -s "smtpServer.user="
      -s "smtpServer.password="
    )
  fi

  kcadm_run_sensitive "${smtp_args[@]}" >/dev/null
  echo "[keycloak-iac] SMTP configured for realm ${REALM} at ${smtp_host}:${smtp_port}"
else
  echo "[keycloak-iac] OUROS_SMTP_HOST not set; SMTP reconciliation skipped"
fi
