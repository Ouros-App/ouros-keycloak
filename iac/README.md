# Keycloak clients as code

The `iac/` directory is the source of truth for managed resource-server clients in the `ouros` realm.

On every container start, Keycloak starts normally and the bootstrap wrapper waits for the local Admin API. It then runs `sync-clients.sh`, which reconciles every file under `iac/resources/` using the bundled `kcadm.sh` CLI.

## Adding a new API

Create one file in `iac/resources/` and open a PR:

```bash
# iac/resources/ms-example-api.conf
CLIENT_ID="ms-example-api"
AUDIENCE="ms-example-api"
SCOPE_NAME="ms-example-api-audience"
MAPPER_NAME="ms-example-api-audience"
```

After the PR is merged and the Discloud application is redeployed, the reconciler will:

1. create or update the OIDC client;
2. keep login flows disabled for the resource-server client;
3. create the audience client scope if it does not exist;
4. create or update an `Audience` protocol mapper;
5. add the client ID to the access-token `aud` claim;
6. attach the audience scope to the client as a default scope.

The operation is idempotent, so redeploying the same configuration is safe.

## Authentication used by the reconciler

Configure a permanent Keycloak administrator in the Discloud environment:

```env
KC_IAC_ADMIN_USERNAME=...
KC_IAC_ADMIN_PASSWORD=...
KC_IAC_REALM=ouros
```

The first rollout may fall back to `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD`, which is useful while the temporary bootstrap administrator still exists. Before deleting that temporary administrator, configure the permanent IaC credentials.

The `kcadm` session is stored only under `/tmp/keycloak-iac` inside the running container.

## Safety model

The reconciler is intentionally non-destructive. It creates and updates resources declared in Git, but deleting a `.conf` file does **not** automatically delete the live Keycloak client. Removing an identity resource should be an explicit operation in a dedicated PR rather than an accidental side effect of a rename.

Secrets never belong in `iac/resources/`. Client secrets and administrator passwords remain environment-managed.

## Audience note

These files manage resource-server identities and their audience scopes. The client that actually obtains a user token must also request or receive the appropriate audience scope according to the final authentication/token-exchange flow. Keeping the resource server and token issuer responsibilities separate prevents `client_credentials` tokens from being mistaken for user tokens.
