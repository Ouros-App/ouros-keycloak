#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ouros-keycloak:ci"
NETWORK="ouros-keycloak-ci-${GITHUB_RUN_ID:-$$}"
POSTGRES_CONTAINER="ouros-keycloak-postgres-${GITHUB_RUN_ID:-$$}"
KEYCLOAK_CONTAINER="ouros-keycloak-app-${GITHUB_RUN_ID:-$$}"
HOST_PORT="18080"
ADMIN_USER="ci-admin"
ADMIN_PASSWORD="ci-admin-password"
DB_PASSWORD="ci-db-password"

cleanup() {
  docker rm -f "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

print_keycloak_logs() {
  echo "[integration] Keycloak logs:" >&2
  docker logs "${KEYCLOAK_CONTAINER}" >&2 2>/dev/null || true
}

print_keycloak_state() {
  docker inspect "${KEYCLOAK_CONTAINER}" \
    --format='[integration] exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' >&2 2>/dev/null || true
}

on_error() {
  local status=$?
  trap - ERR
  print_keycloak_state
  print_keycloak_logs
  exit "${status}"
}
trap on_error ERR

jwt_payload() {
  local token="$1"
  local segment padding

  segment="$(cut -d. -f2 <<< "${token}")"
  segment="${segment//-/+}"
  segment="${segment//_/\/}"

  case $(( ${#segment} % 4 )) in
    2) padding='==' ;;
    3) padding='=' ;;
    *) padding='' ;;
  esac

  printf '%s%s' "${segment}" "${padding}" | base64 --decode
}

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "base64 is required" >&2; exit 1; }

echo "[integration] building Keycloak image"
docker build -t "${IMAGE}" .

docker network create "${NETWORK}" >/dev/null

echo "[integration] starting PostgreSQL"
docker run -d \
  --name "${POSTGRES_CONTAINER}" \
  --memory 512m \
  --network "${NETWORK}" \
  --network-alias keycloak-db \
  -e POSTGRES_DB=keycloak \
  -e POSTGRES_USER=keycloak \
  -e POSTGRES_PASSWORD="${DB_PASSWORD}" \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 45); do
  if docker exec "${POSTGRES_CONTAINER}" pg_isready -U keycloak -d keycloak >/dev/null 2>&1; then
    break
  fi
  sleep 1
  docker inspect "${POSTGRES_CONTAINER}" --format '{{.State.Running}}' | grep -qx true \
    || { echo "[integration] PostgreSQL exited unexpectedly" >&2; exit 1; }
done

docker exec "${POSTGRES_CONTAINER}" pg_isready -U keycloak -d keycloak >/dev/null

echo "[integration] starting Keycloak with all client types"
docker run -d \
  --name "${KEYCLOAK_CONTAINER}" \
  --memory 2048m \
  --network "${NETWORK}" \
  -p "${HOST_PORT}:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${ADMIN_USER}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  -e KC_IAC_ADMIN_USERNAME="${ADMIN_USER}" \
  -e KC_IAC_ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  -e KC_IAC_REALM=ouros \
  -e KC_IAC_RESOURCE_DIR=/opt/keycloak/iac/test-fixtures \
  -e KC_HOSTNAME="http://localhost:${HOST_PORT}" \
  -e KC_DB_URL=jdbc:postgresql://keycloak-db:5432/keycloak \
  -e KC_DB_USERNAME=keycloak \
  -e KCRAW_DB_PASSWORD="${DB_PASSWORD}" \
  "${IMAGE}" >/dev/null

ready=false
for _ in $(seq 1 90); do
  if curl -fsS "http://localhost:${HOST_PORT}/realms/ouros/.well-known/openid-configuration" >/dev/null 2>&1 \
    && docker logs "${KEYCLOAK_CONTAINER}" 2>&1 | grep -q '\[keycloak-iac\] reconciliation complete'; then
    ready=true
    break
  fi
  if ! docker inspect "${KEYCLOAK_CONTAINER}" --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
    echo "[integration] Keycloak exited before IaC reconciliation completed" >&2
    print_keycloak_state
    print_keycloak_logs
    exit 1
  fi
  sleep 2
done

if [[ "${ready}" != true ]]; then
  echo "[integration] Keycloak/IaC readiness timed out" >&2
  print_keycloak_state
  print_keycloak_logs
  exit 1
fi

echo "[integration] authenticating verifier"
docker exec -e HOME=/tmp/ci-verify "${KEYCLOAK_CONTAINER}" /bin/bash -lc \
  'mkdir -p "$HOME/.keycloak" && chmod 700 "$HOME" "$HOME/.keycloak"'
docker exec -e HOME=/tmp/ci-verify "${KEYCLOAK_CONTAINER}" \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://127.0.0.1:8080 \
  --realm master \
  --user "${ADMIN_USER}" \
  --password "${ADMIN_PASSWORD}" >/dev/null

kcadm_get() {
  docker exec -e HOME=/tmp/ci-verify "${KEYCLOAK_CONTAINER}" \
    /opt/keycloak/bin/kcadm.sh get "$@"
}

api_json="$(kcadm_get clients -r ouros -q clientId=ci-api)"
mobile_json="$(kcadm_get clients -r ouros -q clientId=ci-mobile)"
web_json="$(kcadm_get clients -r ouros -q clientId=ci-web)"
service_json="$(kcadm_get clients -r ouros -q clientId=ci-service)"

jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false' <<< "${api_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == true and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false and .[0].attributes["pkce.code.challenge.method"] == "S256" and (.[0].redirectUris | index("com.ouros.ci:/oauth2redirect") != null)' <<< "${mobile_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == true and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false and .[0].attributes["pkce.code.challenge.method"] == "S256" and (.[0].redirectUris | index("https://ci.example.invalid/*") != null) and (.[0].webOrigins | index("https://ci.example.invalid") != null)' <<< "${web_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == false and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == true and .[0].clientAuthenticatorType == "client-secret"' <<< "${service_json}" >/dev/null

api_uuid="$(jq -r '.[0].id' <<< "${api_json}")"
mobile_uuid="$(jq -r '.[0].id' <<< "${mobile_json}")"
web_uuid="$(jq -r '.[0].id' <<< "${web_json}")"
service_uuid="$(jq -r '.[0].id' <<< "${service_json}")"

scope_json="$(kcadm_get client-scopes -r ouros)"
scope_uuid="$(jq -r '.[] | select(.name == "ci-api-audience") | .id' <<< "${scope_json}")"
[[ -n "${scope_uuid}" && "${scope_uuid}" != null ]] || { echo "[integration] ci-api-audience scope missing" >&2; exit 1; }

mapper_json="$(kcadm_get "client-scopes/${scope_uuid}/protocol-mappers/models" -r ouros)"
jq -e '.[] | select(.name == "ci-api-audience" and .protocolMapper == "oidc-audience-mapper" and .config["included.client.audience"] == "ci-api" and .config["access.token.claim"] == "true")' <<< "${mapper_json}" >/dev/null

mobile_scopes="$(kcadm_get "clients/${mobile_uuid}/default-client-scopes" -r ouros)"
web_scopes="$(kcadm_get "clients/${web_uuid}/default-client-scopes" -r ouros)"
service_scopes="$(kcadm_get "clients/${service_uuid}/default-client-scopes" -r ouros)"
api_scopes="$(kcadm_get "clients/${api_uuid}/default-client-scopes" -r ouros)"

jq -e '.[] | select(.name == "ci-api-audience")' <<< "${mobile_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${web_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${service_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${api_scopes}" >/dev/null

echo "[integration] verifying Client Credentials service identity"
service_secret="$(kcadm_get "clients/${service_uuid}/client-secret" -r ouros | jq -r '.value')"
[[ -n "${service_secret}" && "${service_secret}" != null ]] \
  || { echo "[integration] service client secret missing" >&2; exit 1; }

service_token_json="$(curl -fsS \
  -u "ci-service:${service_secret}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
service_access_token="$(jq -r '.access_token' <<< "${service_token_json}")"
[[ -n "${service_access_token}" && "${service_access_token}" != null ]] \
  || { echo "[integration] service access token missing" >&2; exit 1; }

service_payload="$(jwt_payload "${service_access_token}")"
jq -e '(.sub | type) == "string" and (if (.aud | type) == "array" then (.aud | index("ci-api")) != null else .aud == "ci-api" end)' \
  <<< "${service_payload}" >/dev/null

echo "[integration] verifying idempotent reconciliation"
docker exec "${KEYCLOAK_CONTAINER}" /bin/bash /opt/keycloak/iac/sync-clients.sh >/dev/null

curl -fsS "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/certs" \
  | jq -e '.keys | length > 0' >/dev/null

echo "[integration] microservice, mobile, web and service IaC reconciliation passed"
