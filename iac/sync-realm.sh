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

kcadm_run get "realms/${REALM}" >/dev/null

ensure_realm_role() {
  local role_name="$1"
  local description="$2"
  local roles_csv

  roles_csv="$(kcadm_run get roles -r "${REALM}" --fields name --format csv --noquotes)"
  if grep -Fxq "${role_name}" <<< "${roles_csv}"; then
    kcadm_run update "roles/${role_name}" -r "${REALM}"       -s "name=${role_name}"       -s "description=${description}" >/dev/null
    echo "[keycloak-iac] updated realm role ${role_name}"
  else
    kcadm_run create roles -r "${REALM}"       -s "name=${role_name}"       -s "description=${description}" >/dev/null
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
