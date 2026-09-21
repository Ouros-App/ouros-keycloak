#!/usr/bin/env bash
set -Eeuo pipefail

KEYCLOAK_PID=""
IAC_ADMIN_USERNAME="${KC_IAC_ADMIN_USERNAME:-${KC_BOOTSTRAP_ADMIN_USERNAME:-}}"
IAC_ADMIN_PASSWORD="${KC_IAC_ADMIN_PASSWORD:-${KC_BOOTSTRAP_ADMIN_PASSWORD:-}}"
RECOVERY_ADMIN_USERNAME="${KC_RECOVERY_ADMIN_USERNAME:-}"
RECOVERY_ADMIN_PASSWORD="${KC_RECOVERY_ADMIN_PASSWORD:-}"

shutdown_keycloak() {
  if [[ -n "${KEYCLOAK_PID}" ]] && kill -0 "${KEYCLOAK_PID}" 2>/dev/null; then
    kill -TERM "${KEYCLOAK_PID}" 2>/dev/null || true
    wait "${KEYCLOAK_PID}" || true
  fi
}

trap shutdown_keycloak INT TERM

if [[ -z "${IAC_ADMIN_USERNAME}" || -z "${IAC_ADMIN_PASSWORD}" ]]; then
  echo "[keycloak-iac] missing KC_IAC_ADMIN_USERNAME/KC_IAC_ADMIN_PASSWORD"
  echo "[keycloak-iac] bootstrap admin variables are accepted only as a fallback"
  exit 1
fi

if [[ -n "${RECOVERY_ADMIN_USERNAME}" || -n "${RECOVERY_ADMIN_PASSWORD}" ]]; then
  if [[ -z "${RECOVERY_ADMIN_USERNAME}" || -z "${RECOVERY_ADMIN_PASSWORD}" ]]; then
    echo "[keycloak-iac] KC_RECOVERY_ADMIN_USERNAME and KC_RECOVERY_ADMIN_PASSWORD must be configured together" >&2
    exit 1
  fi

  # Recovery must happen while Keycloak is stopped. This creates a temporary
  # master-realm administrator; it is removed after the permanent IaC admin
  # has received the master realm admin role and reconciliation succeeds.
  echo "[keycloak-iac] creating temporary recovery administrator"
  set +e
  recovery_bootstrap_output="$(
    /opt/keycloak/bin/kc.sh bootstrap-admin user --optimized \
      --username "${RECOVERY_ADMIN_USERNAME}" \
      --password:env KC_RECOVERY_ADMIN_PASSWORD \
      --no-prompt 2>&1
  )"
  recovery_bootstrap_status=$?
  set -e

  if (( recovery_bootstrap_status != 0 )); then
    # A previous interrupted recovery may already have created this temporary
    # user. Reuse it with the same secret; fail closed for every other error.
    if grep -qiE 'user.*(already )?exists|username.*exists' <<< "${recovery_bootstrap_output}"; then
      echo "[keycloak-iac] temporary recovery administrator already exists; reusing it"
    else
      echo "[keycloak-iac] failed to create temporary recovery administrator" >&2
      printf '%s\n' "${recovery_bootstrap_output}" >&2
      exit "${recovery_bootstrap_status}"
    fi
  fi
fi

/opt/keycloak/bin/kc.sh start --optimized --import-realm &
KEYCLOAK_PID=$!

export HOME="/tmp/keycloak-iac"
mkdir -p "${HOME}/.keycloak"
chmod 700 "${HOME}" "${HOME}/.keycloak"

export KC_OPTS="${KC_IAC_CLI_JAVA_OPTS:--Xms32m -Xmx192m}"

authenticate_kcadm() {
  local username="$1"
  local password="$2"
  local attempt=1
  local max_attempts=60

  export KC_CLI_PASSWORD="${password}"
  until /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://127.0.0.1:8080 \
    --realm master \
    --user "${username}" >/dev/null 2>&1; do
    if ! kill -0 "${KEYCLOAK_PID}" 2>/dev/null; then
      unset KC_CLI_PASSWORD
      echo "[keycloak-iac] Keycloak exited before the IaC reconciliation could run"
      wait "${KEYCLOAK_PID}" || true
      exit 1
    fi

    if (( attempt >= max_attempts )); then
      unset KC_CLI_PASSWORD
      echo "[keycloak-iac] timed out waiting for the Keycloak Admin API"
      shutdown_keycloak
      exit 1
    fi

    sleep 2
    ((attempt += 1))
  done
  unset KC_CLI_PASSWORD
}

if [[ -n "${RECOVERY_ADMIN_USERNAME}" ]]; then
  authenticate_kcadm "${RECOVERY_ADMIN_USERNAME}" "${RECOVERY_ADMIN_PASSWORD}"

  echo "[keycloak-iac] granting master realm admin to ${IAC_ADMIN_USERNAME}"
  /opt/keycloak/bin/kcadm.sh add-roles -r master \
    --uusername "${IAC_ADMIN_USERNAME}" \
    --rolename admin >/dev/null

  # Do not keep using the recovery identity. Prove that the permanent
  # credential can administer the target realm before IaC is executed.
  authenticate_kcadm "${IAC_ADMIN_USERNAME}" "${IAC_ADMIN_PASSWORD}"
else
  authenticate_kcadm "${IAC_ADMIN_USERNAME}" "${IAC_ADMIN_PASSWORD}"
fi

echo "[keycloak-iac] Admin API ready; reconciling managed resources"
bash /opt/keycloak/iac/sync-realm.sh
bash /opt/keycloak/iac/sync-clients.sh
bash /opt/keycloak/iac/sync-user-storage.sh
bash /opt/keycloak/iac/sync-email-otp.sh

if [[ -n "${RECOVERY_ADMIN_USERNAME}" ]]; then
  recovery_user_response="$(
    /opt/keycloak/bin/kcadm.sh get users -r master \
      -q "username=${RECOVERY_ADMIN_USERNAME}" \
      --fields id
  )"

  # The Keycloak production image intentionally omits awk and other utility
  # packages. Extract the single user id with Bash itself so cleanup works in
  # the same minimal image used by Discloud.
  recovery_user_id=""
  if [[ "${recovery_user_response}" =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    recovery_user_id="${BASH_REMATCH[1]}"
  fi

  if [[ -z "${recovery_user_id}" ]]; then
    echo "[keycloak-iac] recovery admin could not be found for cleanup" >&2
    shutdown_keycloak
    exit 1
  fi

  /opt/keycloak/bin/kcadm.sh delete "users/${recovery_user_id}" -r master
  echo "[keycloak-iac] temporary recovery administrator removed"
fi

echo "[keycloak-iac] reconciliation complete"
wait "${KEYCLOAK_PID}"
