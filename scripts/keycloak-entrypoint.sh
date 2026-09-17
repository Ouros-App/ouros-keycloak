#!/usr/bin/env bash
set -Eeuo pipefail

KEYCLOAK_PID=""

shutdown_keycloak() {
  if [[ -n "${KEYCLOAK_PID}" ]] && kill -0 "${KEYCLOAK_PID}" 2>/dev/null; then
    kill -TERM "${KEYCLOAK_PID}" 2>/dev/null || true
    wait "${KEYCLOAK_PID}" || true
  fi
}

trap shutdown_keycloak INT TERM

/opt/keycloak/bin/kc.sh start --optimized --import-realm &
KEYCLOAK_PID=$!

IAC_ADMIN_USERNAME="${KC_IAC_ADMIN_USERNAME:-${KC_BOOTSTRAP_ADMIN_USERNAME:-}}"
IAC_ADMIN_PASSWORD="${KC_IAC_ADMIN_PASSWORD:-${KC_BOOTSTRAP_ADMIN_PASSWORD:-}}"

if [[ -z "${IAC_ADMIN_USERNAME}" || -z "${IAC_ADMIN_PASSWORD}" ]]; then
  echo "[keycloak-iac] missing KC_IAC_ADMIN_USERNAME/KC_IAC_ADMIN_PASSWORD"
  echo "[keycloak-iac] bootstrap admin variables are accepted only as a fallback"
  shutdown_keycloak
  exit 1
fi

export HOME="/tmp/keycloak-iac"
mkdir -p "${HOME}/.keycloak"
chmod 700 "${HOME}" "${HOME}/.keycloak"

export KC_OPTS="${KC_IAC_CLI_JAVA_OPTS:--Xms32m -Xmx192m}"
export KC_CLI_PASSWORD="${IAC_ADMIN_PASSWORD}"

attempt=1
max_attempts=60
until /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://127.0.0.1:8080 \
  --realm master \
  --user "${IAC_ADMIN_USERNAME}" >/dev/null 2>&1; do
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

echo "[keycloak-iac] Admin API ready; reconciling managed resources"
bash /opt/keycloak/iac/sync-clients.sh
bash /opt/keycloak/iac/sync-user-storage.sh

echo "[keycloak-iac] reconciliation complete"
wait "${KEYCLOAK_PID}"
