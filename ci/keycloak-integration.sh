#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ouros-keycloak:ci"
NETWORK="ouros-keycloak-ci-${GITHUB_RUN_ID:-$$}"
POSTGRES_CONTAINER="ouros-keycloak-postgres-${GITHUB_RUN_ID:-$$}"
KEYCLOAK_CONTAINER="ouros-keycloak-app-${GITHUB_RUN_ID:-$}"
AUTH_CONTAINER="ouros-keycloak-auth-${GITHUB_RUN_ID:-$}"
HOST_PORT="18080"
ADMIN_USER="ci-admin"
ADMIN_PASSWORD="ci-admin-password"
DB_PASSWORD="ci-db-password"

cleanup() {
  docker rm -f "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${AUTH_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

print_keycloak_logs() {
  echo "[integration] Keycloak logs:" >&2
  docker logs "${KEYCLOAK_CONTAINER}" >&2 2>&1 || true
}

print_keycloak_state() {
  docker inspect "${KEYCLOAK_CONTAINER}" \
    --format='[integration] exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' >&2 2>&1 || true
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

verify_jwt_with_jwks() {
  local token="$1"
  local audience="$2"

  docker exec -i \
    -e JWT_TOKEN="${token}" \
    -e JWT_ISSUER="http://localhost:${HOST_PORT}/realms/ouros" \
    -e JWT_AUDIENCE="${audience}" \
    -e JWT_JWKS_URL="http://${KEYCLOAK_CONTAINER}:8080/realms/ouros/protocol/openid-connect/certs" \
    "${AUTH_CONTAINER}" python - <<'PY'
import json
import os

import jwt
from jwt import PyJWKClient

token = os.environ["JWT_TOKEN"]
jwks_url = os.environ["JWT_JWKS_URL"]
issuer = os.environ["JWT_ISSUER"]
audience = os.environ["JWT_AUDIENCE"]

signing_key = PyJWKClient(jwks_url).get_signing_key_from_jwt(token)
claims = jwt.decode(
    token,
    signing_key.key,
    algorithms=["RS256"],
    issuer=issuer,
    audience=audience,
    options={"require": ["exp", "iat", "iss", "aud", "sub"]},
)
print(json.dumps(claims, separators=(",", ":")))
PY
}

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "base64 is required" >&2; exit 1; }

provider_jar="${PWD}/providers/ouros-user-storage/target/ouros-user-storage-1.0.0.jar"
if [[ ! -s "${provider_jar}" ]]; then
  echo "[integration] provider artifact missing; building fallback for local execution"
  docker run --rm \
    -v "${PWD}:/workspace" \
    -w /workspace/providers/ouros-user-storage \
    maven:3.9.9-eclipse-temurin-21 \
    mvn -B -q package -DskipTests
fi

echo "[integration] building Keycloak image"
docker build -t "${IMAGE}" .

docker network create "${NETWORK}" >/dev/null

echo "[integration] starting mock Ouros auth service"
docker run -d \
  --name "${AUTH_CONTAINER}" \
  --network "${NETWORK}" \
  --network-alias mock-auth-service \
  -v "${PWD}:/workspace:ro" \
  python:3.12-alpine \
  python /workspace/ci/mock-auth-service.py >/dev/null

docker exec "${AUTH_CONTAINER}" \
  pip install --quiet --disable-pip-version-check 'PyJWT[crypto]==2.14.0'

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

postgres_ready=false
for _ in $(seq 1 60); do
  if docker logs "${POSTGRES_CONTAINER}" 2>&1 \
      | grep -q 'PostgreSQL init process complete; ready for start up.' \
    && docker exec "${POSTGRES_CONTAINER}" pg_isready -U keycloak -d keycloak >/dev/null 2>&1; then
    postgres_ready=true
    break
  fi

  docker inspect "${POSTGRES_CONTAINER}" --format '{{.State.Running}}' 2>/dev/null \
    | grep -qx true \
    || { echo "[integration] PostgreSQL exited unexpectedly" >&2; docker logs "${POSTGRES_CONTAINER}" >&2 || true; exit 1; }
  sleep 1
done

if [[ "${postgres_ready}" != true ]]; then
  echo "[integration] PostgreSQL readiness timed out" >&2
  docker logs "${POSTGRES_CONTAINER}" >&2 || true
  exit 1
fi

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
  -e KC_IAC_USER_STORAGE_FILE=/opt/keycloak/iac/test-fixtures/user-storage/ouros-auth-service.conf \
  -e KC_HOSTNAME="http://localhost:${HOST_PORT}" \
  -e KC_DB_URL=jdbc:postgresql://keycloak-db:5432/keycloak \
  -e KC_DB_USERNAME=keycloak \
  -e KCRAW_DB_PASSWORD="${DB_PASSWORD}" \
  -e OUROS_SMTP_HOST=mailpit \
  -e OUROS_SMTP_PORT=1025 \
  -e OUROS_SMTP_AUTH=false \
  -e OUROS_SMTP_STARTTLS=false \
  -e OUROS_SMTP_SSL=false \
  -e OUROS_EMAIL_OTP_ENABLED=true \
  -e OUROS_EMAIL_OTP_HMAC_SECRET=ci-email-otp-hmac-secret-0123456789abcdef \
  -e OUROS_EMAIL_OTP_TTL_SECONDS=300 \
  -e OUROS_EMAIL_OTP_MAX_ATTEMPTS=5 \
  -e OUROS_EMAIL_OTP_RESEND_COOLDOWN_SECONDS=30 \
  "${IMAGE}" >/dev/null

ready=false
for _ in $(seq 1 150); do
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

realm_json="$(kcadm_get realms/ouros)"
jq -e '
  .enabled == true
  and .sslRequired == "external"
  and .registrationAllowed == false
  and .resetPasswordAllowed == false
  and .verifyEmail == false
  and .bruteForceProtected == true
  and .browserFlow == "ouros-browser-email-otp"
  and .smtpServer.host == "mailpit"
  and .smtpServer.port == "1025"
  and .smtpServer.auth == "false"
  and .smtpServer.starttls == "false"
  and .smtpServer.ssl == "false"
' <<< "${realm_json}" >/dev/null

email_otp_executions="$(kcadm_get authentication/flows/ouros-browser-email-otp/executions -r ouros)"
jq -e '
  any(.[]; .providerId == "auth-username-password-form" and .requirement == "REQUIRED")
  and any(.[]; .providerId == "ouros-email-otp" and .requirement == "REQUIRED")
' <<< "${email_otp_executions}" >/dev/null

roles_json="$(kcadm_get roles -r ouros)"
for managed_role in farm_owner company_employee admin; do
  jq -e --arg role "${managed_role}" '.[] | select(.name == $role)' <<< "${roles_json}" >/dev/null
done

api_json="$(kcadm_get clients -r ouros -q clientId=ci-api)"
mobile_json="$(kcadm_get clients -r ouros -q clientId=ci-mobile)"
web_json="$(kcadm_get clients -r ouros -q clientId=ci-web)"
service_json="$(kcadm_get clients -r ouros -q clientId=ci-service)"
token_exchange_json="$(kcadm_get clients -r ouros -q clientId=ci-token-exchange)"
auth_api_json="$(kcadm_get clients -r ouros -q clientId=ci-auth-api)"
debug_grant_json="$(kcadm_get clients -r ouros -q clientId=ci-debug-password-grant)"
user_storage_service_json="$(kcadm_get clients -r ouros -q clientId=ci-user-storage)"

jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false' <<< "${api_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == true and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false and .[0].attributes["pkce.code.challenge.method"] == "S256" and (.[0].redirectUris | index("com.ouros.ci:/oauth2redirect") != null)' <<< "${mobile_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == true and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false and .[0].attributes["pkce.code.challenge.method"] == "S256" and (.[0].redirectUris | index("https://ci.example.invalid/*") != null) and (.[0].webOrigins | index("https://ci.example.invalid") != null)' <<< "${web_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == false and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == true and .[0].clientAuthenticatorType == "client-secret"' <<< "${service_json}" >/dev/null
jq -e 'length == 1
  and .[0].publicClient == false
  and .[0].standardFlowEnabled == false
  and .[0].directAccessGrantsEnabled == false
  and .[0].implicitFlowEnabled == false
  and .[0].serviceAccountsEnabled == false
  and .[0].clientAuthenticatorType == "client-secret"
  and .[0].attributes["standard.token.exchange.enabled"] == "true"' <<< "${token_exchange_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == true and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false' <<< "${auth_api_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == false and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == true and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == false and .[0].clientAuthenticatorType == "client-secret"' <<< "${debug_grant_json}" >/dev/null
jq -e 'length == 1 and .[0].publicClient == false and .[0].standardFlowEnabled == false and .[0].directAccessGrantsEnabled == false and .[0].implicitFlowEnabled == false and .[0].serviceAccountsEnabled == true and .[0].clientAuthenticatorType == "client-secret"' <<< "${user_storage_service_json}" >/dev/null

api_uuid="$(jq -r '.[0].id' <<< "${api_json}")"
mobile_uuid="$(jq -r '.[0].id' <<< "${mobile_json}")"
web_uuid="$(jq -r '.[0].id' <<< "${web_json}")"
service_uuid="$(jq -r '.[0].id' <<< "${service_json}")"
token_exchange_uuid="$(jq -r '.[0].id' <<< "${token_exchange_json}")"
auth_api_uuid="$(jq -r '.[0].id' <<< "${auth_api_json}")"
debug_grant_uuid="$(jq -r '.[0].id' <<< "${debug_grant_json}")"
user_storage_service_uuid="$(jq -r '.[0].id' <<< "${user_storage_service_json}")"

scope_json="$(kcadm_get client-scopes -r ouros)"
scope_uuid="$(jq -r '.[] | select(.name == "ci-api-audience") | .id' <<< "${scope_json}")"
identity_scope_uuid="$(jq -r '.[] | select(.name == "ouros-identity") | .id' <<< "${scope_json}")"
[[ -n "${scope_uuid}" && "${scope_uuid}" != null ]] || { echo "[integration] ci-api-audience scope missing" >&2; exit 1; }
[[ -n "${identity_scope_uuid}" && "${identity_scope_uuid}" != null ]] || { echo "[integration] ouros-identity scope missing" >&2; exit 1; }

mapper_json="$(kcadm_get "client-scopes/${scope_uuid}/protocol-mappers/models" -r ouros)"
jq -e '.[] | select(.name == "ci-api-audience" and .protocolMapper == "oidc-audience-mapper" and .config["included.client.audience"] == "ci-api" and .config["access.token.claim"] == "true")' <<< "${mapper_json}" >/dev/null

identity_mappers="$(kcadm_get "client-scopes/${identity_scope_uuid}/protocol-mappers/models" -r ouros)"
jq -e '
  map(select(.protocolMapper == "oidc-usermodel-attribute-mapper")) as $mappers
  | ($mappers | length) == 5
  and any($mappers[]; .name == "ouros-database_id" and .config["user.attribute"] == "database_id" and .config["claim.name"] == "database_id" and .config["jsonType.label"] == "long" and .config["access.token.claim"] == "true")
  and any($mappers[]; .name == "ouros-account_type" and .config["user.attribute"] == "account_type" and .config["claim.name"] == "account_type" and .config["jsonType.label"] == "String" and .config["access.token.claim"] == "true")
  and any($mappers[]; .name == "ouros-farm_id" and .config["user.attribute"] == "farm_id" and .config["claim.name"] == "farm_id" and .config["jsonType.label"] == "long" and .config["access.token.claim"] == "true")
  and any($mappers[]; .name == "ouros-enterprise_id" and .config["user.attribute"] == "enterprise_id" and .config["claim.name"] == "enterprise_id" and .config["jsonType.label"] == "long" and .config["access.token.claim"] == "true")
  and any($mappers[]; .name == "ouros-first_access" and .config["user.attribute"] == "first_access" and .config["claim.name"] == "first_access" and .config["jsonType.label"] == "boolean" and .config["access.token.claim"] == "true")
' <<< "${identity_mappers}" >/dev/null

mobile_scopes="$(kcadm_get "clients/${mobile_uuid}/default-client-scopes" -r ouros)"
web_scopes="$(kcadm_get "clients/${web_uuid}/default-client-scopes" -r ouros)"
service_scopes="$(kcadm_get "clients/${service_uuid}/default-client-scopes" -r ouros)"
token_exchange_scopes="$(kcadm_get "clients/${token_exchange_uuid}/default-client-scopes" -r ouros)"
api_scopes="$(kcadm_get "clients/${api_uuid}/default-client-scopes" -r ouros)"
auth_api_scopes="$(kcadm_get "clients/${auth_api_uuid}/default-client-scopes" -r ouros)"
debug_grant_scopes="$(kcadm_get "clients/${debug_grant_uuid}/default-client-scopes" -r ouros)"
user_storage_scopes="$(kcadm_get "clients/${user_storage_service_uuid}/default-client-scopes" -r ouros)"

jq -e '.[] | select(.name == "ci-api-audience")' <<< "${mobile_scopes}" >/dev/null
jq -e '.[] | select(.name == "ouros-identity")' <<< "${mobile_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${web_scopes}" >/dev/null
jq -e '.[] | select(.name == "ouros-identity")' <<< "${web_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${service_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${token_exchange_scopes}" >/dev/null
jq -e '.[] | select(.name == "ouros-identity")' <<< "${token_exchange_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${api_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-auth-api-audience")' <<< "${auth_api_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-api-audience")' <<< "${debug_grant_scopes}" >/dev/null
jq -e '.[] | select(.name == "ouros-identity")' <<< "${debug_grant_scopes}" >/dev/null
jq -e '.[] | select(.name == "ci-auth-api-audience")' <<< "${user_storage_scopes}" >/dev/null

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

echo "[integration] verifying User Storage service identity and component"
user_storage_secret="$(kcadm_get "clients/${user_storage_service_uuid}/client-secret" -r ouros | jq -r '.value')"
[[ -n "${user_storage_secret}" && "${user_storage_secret}" != null ]] \
  || { echo "[integration] user-storage service secret missing" >&2; exit 1; }

user_storage_token_json="$(curl -fsS \
  -u "ci-user-storage:${user_storage_secret}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
user_storage_access_token="$(jq -r '.access_token' <<< "${user_storage_token_json}")"
user_storage_payload="$(jwt_payload "${user_storage_access_token}")"
jq -e '(.azp == "ci-user-storage") and (if (.aud | type) == "array" then (.aud | index("ci-auth-api")) != null else .aud == "ci-auth-api" end)' \
  <<< "${user_storage_payload}" >/dev/null

components_json="$(kcadm_get components -r ouros -q type=org.keycloak.storage.UserStorageProvider -q name=ouros-auth-service)"
jq -e 'length == 1
  and .[0].providerId == "ouros-auth-service"
  and .[0].config.authServiceUrl[0] == "http://mock-auth-service:8081"
  and .[0].config.serviceClientId[0] == "ci-user-storage"
  and (. [0].config.serviceClientSecret[0] | length) > 0' <<< "${components_json}" >/dev/null

echo "[integration] verifying external-user password login produces user tokens"
docker exec -e HOME=/tmp/ci-verify "${KEYCLOAK_CONTAINER}" \
  /opt/keycloak/bin/kcadm.sh create clients -r ouros \
  -s clientId=ci-login-test \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=true \
  -s implicitFlowEnabled=false \
  -s serviceAccountsEnabled=false >/dev/null

ci_login_json="$(kcadm_get clients -r ouros -q clientId=ci-login-test)"
ci_login_uuid="$(jq -r '.[0].id' <<< "${ci_login_json}")"
[[ -n "${ci_login_uuid}" && "${ci_login_uuid}" != null ]] \
  || { echo "[integration] ci-login-test client missing" >&2; exit 1; }
docker exec -e HOME=/tmp/ci-verify "${KEYCLOAK_CONTAINER}" \
  /opt/keycloak/bin/kcadm.sh update "clients/${ci_login_uuid}/default-client-scopes/${identity_scope_uuid}" \
  -r ouros -n >/dev/null

wrong_login_file="$(mktemp)"
wrong_login_status="$(curl -sS -o "${wrong_login_file}" -w '%{http_code}' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=ci-login-test' \
  --data-urlencode 'username=ci-user@example.com' \
  --data-urlencode 'password=wrong-password' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
[[ "${wrong_login_status}" == 400 ]] \
  || { echo "[integration] wrong password returned HTTP ${wrong_login_status}" >&2; cat "${wrong_login_file}" >&2; rm -f "${wrong_login_file}"; exit 1; }
jq -e '.error == "invalid_grant"' "${wrong_login_file}" >/dev/null
rm -f "${wrong_login_file}"

login_token_file="$(mktemp)"
login_token_status="$(curl -sS -o "${login_token_file}" -w '%{http_code}' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=ci-login-test' \
  --data-urlencode 'username=ci-user@example.com' \
  --data-urlencode 'password=ci-password' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
if [[ "${login_token_status}" != 200 ]]; then
  echo "[integration] valid external-user login returned HTTP ${login_token_status}" >&2
  cat "${login_token_file}" >&2
  rm -f "${login_token_file}"
  exit 1
fi
login_token_json="$(cat "${login_token_file}")"
rm -f "${login_token_file}"
login_access_token="$(jq -r '.access_token' <<< "${login_token_json}")"
login_refresh_token="$(jq -r '.refresh_token' <<< "${login_token_json}")"
[[ -n "${login_access_token}" && "${login_access_token}" != null ]] \
  || { echo "[integration] external-user access token missing" >&2; exit 1; }
[[ -n "${login_refresh_token}" && "${login_refresh_token}" != null ]] \
  || { echo "[integration] external-user refresh token missing" >&2; exit 1; }

login_payload="$(jwt_payload "${login_access_token}")"
if ! jq -e '(.sub | type) == "string"
  and (.preferred_username == "ci-user@example.com")
  and (.realm_access.roles | index("farm_owner") != null)
  and (.database_id == 42)
  and (.account_type == "farm_owner")
  and (.farm_id == 7)
  and (.first_access == false)
  and (has("enterprise_id") | not)' <<< "${login_payload}" >/dev/null; then
  echo "[integration] external-user token claims did not match the federated identity" >&2
  jq . <<< "${login_payload}" >&2
  exit 1
fi

echo "[integration] verifying restricted debug password-grant client"
debug_grant_secret="$(kcadm_get "clients/${debug_grant_uuid}/client-secret" -r ouros | jq -r '.value')"
[[ -n "${debug_grant_secret}" && "${debug_grant_secret}" != null ]] \
  || { echo "[integration] debug password-grant secret missing" >&2; exit 1; }

debug_grant_token_json="$(curl -fsS \
  -u "ci-debug-password-grant:${debug_grant_secret}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  --data-urlencode 'username=ci-user@example.com' \
  --data-urlencode 'password=ci-password' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
debug_grant_access_token="$(jq -r '.access_token' <<< "${debug_grant_token_json}")"
[[ -n "${debug_grant_access_token}" && "${debug_grant_access_token}" != null ]] \
  || { echo "[integration] debug password-grant access token missing" >&2; exit 1; }
debug_grant_payload="$(jwt_payload "${debug_grant_access_token}")"
jq -e '
  (.preferred_username == "ci-user@example.com")
  and (.database_id == 42)
  and (.account_type == "farm_owner")
  and (
    if (.aud | type) == "array" then
      (.aud | index("ci-token-exchange")) != null
      and (.aud | index("ci-auth-api")) != null
      and (.aud | index("ci-api")) == null
      and all(.aud[]; . == "ci-token-exchange" or . == "ci-auth-api" or . == "account")
    else
      false
    end
  )
' <<< "${debug_grant_payload}" >/dev/null

echo "[integration] verifying Standard Token Exchange v2 delegation"
token_exchange_secret="$(kcadm_get "clients/${token_exchange_uuid}/client-secret" -r ouros | jq -r '.value')"
[[ -n "${token_exchange_secret}" && "${token_exchange_secret}" != null ]] \
  || { echo "[integration] token-exchange client secret missing" >&2; exit 1; }

exchanged_token_json="$(curl -fsS \
  -u "ci-token-exchange:${token_exchange_secret}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=${debug_grant_access_token}" \
  --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'audience=ci-api' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
exchanged_access_token="$(jq -r '.access_token' <<< "${exchanged_token_json}")"
[[ -n "${exchanged_access_token}" && "${exchanged_access_token}" != null ]] \
  || { echo "[integration] exchanged access token missing" >&2; exit 1; }

exchanged_payload="$(verify_jwt_with_jwks "${exchanged_access_token}" "ci-api")"
jq -e '
  (.azp == "ci-token-exchange")
  and (.preferred_username == "ci-user@example.com")
  and (.database_id == 42)
  and (.account_type == "farm_owner")
  and (.realm_access.roles | index("farm_owner") != null)
  and (
    if (.aud | type) == "array"
    then (.aud | index("ci-api")) != null and (.aud | index("ci-token-exchange")) == null
    else .aud == "ci-api"
    end
  )
' <<< "${exchanged_payload}" >/dev/null

echo "[integration] verifying Phase 3 first-party broker token contract"
phase3_broker_json="$(kcadm_get clients -r ouros -q clientId=ci-phase3-auth-broker)"
phase3_broker_uuid="$(jq -r '.[0].id' <<< "${phase3_broker_json}")"
[[ -n "${phase3_broker_uuid}" && "${phase3_broker_uuid}" != null ]] \
  || { echo "[integration] Phase 3 broker client missing" >&2; exit 1; }
jq -e 'length == 1
  and .[0].publicClient == false
  and .[0].standardFlowEnabled == false
  and .[0].directAccessGrantsEnabled == true
  and .[0].serviceAccountsEnabled == false
  and .[0].clientAuthenticatorType == "client-secret"' \
  <<< "${phase3_broker_json}" >/dev/null

phase3_broker_secret="$(kcadm_get "clients/${phase3_broker_uuid}/client-secret" -r ouros | jq -r '.value')"
[[ -n "${phase3_broker_secret}" && "${phase3_broker_secret}" != null ]] \
  || { echo "[integration] Phase 3 broker secret missing" >&2; exit 1; }

phase3_token_json="$(curl -fsS \
  -u "ci-phase3-auth-broker:${phase3_broker_secret}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  --data-urlencode 'username=ci-user@example.com' \
  --data-urlencode 'password=ci-password' \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
phase3_access_token="$(jq -r '.access_token' <<< "${phase3_token_json}")"
[[ -n "${phase3_access_token}" && "${phase3_access_token}" != null ]] \
  || { echo "[integration] Phase 3 broker access token missing" >&2; exit 1; }

phase3_payload="$(verify_jwt_with_jwks "${phase3_access_token}" "ms-ai-server")"
if ! jq -e '
  def has_aud($name):
    if (.aud | type) == "array"
    then (.aud | index($name)) != null
    else .aud == $name
    end;
  (.sub | type) == "string"
  and has_aud("ms-spring-api")
  and has_aud("ms-telemetry-dashboard-service")
  and has_aud("ms-ai-server")
  and has_aud("ms-ai-server-mcp-exchange")
  and (has_aud("ms-mcp-server-ouros-knowledge") | not)
  and has_aud("ms-mcp-server-ouros-knowledge-codemode")
  and (.realm_access.roles | index("farm_owner") != null)
  and (.database_id == 42)
  and (.account_type == "farm_owner")
  and (.farm_id == 7)
  and (.first_access == false)
' <<< "${phase3_payload}" >/dev/null; then
  echo "[integration] Phase 3 broker token contract mismatch" >&2
  jq . <<< "${phase3_payload}" >&2
  exit 1
fi

echo "[integration] verifying refresh-token flow preserves federated identity"
refresh_token_json="$(curl -fsS \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=refresh_token' \
  -d 'client_id=ci-login-test' \
  --data-urlencode "refresh_token=${login_refresh_token}" \
  "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/token")"
refreshed_access_token="$(jq -r '.access_token' <<< "${refresh_token_json}")"
refreshed_refresh_token="$(jq -r '.refresh_token' <<< "${refresh_token_json}")"
[[ -n "${refreshed_access_token}" && "${refreshed_access_token}" != null ]] \
  || { echo "[integration] refreshed access token missing" >&2; exit 1; }
[[ -n "${refreshed_refresh_token}" && "${refreshed_refresh_token}" != null ]] \
  || { echo "[integration] refreshed refresh token missing" >&2; exit 1; }

refreshed_payload="$(jwt_payload "${refreshed_access_token}")"
jq -e --arg subject "$(jq -r '.sub' <<< "${login_payload}")" '
  .sub == $subject
  and (.preferred_username == "ci-user@example.com")
  and (.realm_access.roles | index("farm_owner") != null)
  and (.database_id == 42)
  and (.account_type == "farm_owner")
  and (.farm_id == 7)
  and (.first_access == false)
  and (has("enterprise_id") | not)
' <<< "${refreshed_payload}" >/dev/null

echo "[integration] verifying idempotent reconciliation"
docker exec "${KEYCLOAK_CONTAINER}" /bin/bash /opt/keycloak/iac/sync-realm.sh >/dev/null
docker exec "${KEYCLOAK_CONTAINER}" /bin/bash /opt/keycloak/iac/sync-clients.sh >/dev/null
docker exec "${KEYCLOAK_CONTAINER}" /bin/bash /opt/keycloak/iac/sync-user-storage.sh >/dev/null
docker exec "${KEYCLOAK_CONTAINER}" /bin/bash /opt/keycloak/iac/sync-email-otp.sh >/dev/null

components_after_reconcile="$(kcadm_get components -r ouros -q type=org.keycloak.storage.UserStorageProvider -q name=ouros-auth-service)"
jq -e 'length == 1 and .[0].providerId == "ouros-auth-service"' <<< "${components_after_reconcile}" >/dev/null

scopes_after_reconcile="$(kcadm_get client-scopes -r ouros)"
jq -e '[.[] | select(.name == "ouros-identity")] | length == 1' <<< "${scopes_after_reconcile}" >/dev/null
identity_mappers_after_reconcile="$(kcadm_get "client-scopes/${identity_scope_uuid}/protocol-mappers/models" -r ouros)"
jq -e '[.[] | select(.name | startswith("ouros-"))] | length == 5' <<< "${identity_mappers_after_reconcile}" >/dev/null

curl -fsS "http://localhost:${HOST_PORT}/realms/ouros/protocol/openid-connect/certs" \
  | jq -e '.keys | length > 0' >/dev/null

echo "[integration] clients, User Storage SPI, service trust and external-user login passed"
