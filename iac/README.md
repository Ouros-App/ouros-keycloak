# Keycloak clients as code

A pasta `iac/` é a fonte de verdade dos clients gerenciados no realm `ouros`.

Em cada deploy o container sobe o Keycloak, aguarda a Admin API local e executa `sync-realm.sh`, `sync-clients.sh` e `sync-user-storage.sh`. O reconciliador usa o `kcadm.sh` incluído no próprio Keycloak para manter realm, roles, clients, scopes e o User Storage de forma idempotente.

## Tipos suportados

### `microservice`

Representa uma API/resource server.

- não possui login interativo;
- `Standard flow`, `Direct access grants`, `Implicit flow` e service account ficam desativados;
- cria um client scope de audience;
- cria um `Audience Protocol Mapper`;
- adiciona o `CLIENT_ID`/`AUDIENCE` ao claim `aud` dos access tokens que recebem esse scope.

```bash
CLIENT_TYPE="microservice"
CLIENT_ID="ms-example-api"
AUDIENCE="ms-example-api"
SCOPE_NAME="ms-example-api-audience"
MAPPER_NAME="ms-example-api-audience"
```

### `mobile`

Representa o aplicativo nativo.

- public client;
- Authorization Code Flow ativado;
- PKCE obrigatório com `S256`;
- Implicit Flow e Direct Access Grants desativados;
- pode receber audiences de um ou mais microserviços gerenciados.

```bash
CLIENT_TYPE="mobile"
CLIENT_ID="ouros-mobile"
REDIRECT_URIS="com.ouros.app:/oauth2redirect"
AUDIENCES="ms-example-api|ms-another-api"
```

### `web`

Representa o frontend web/SPA.

- public client;
- Authorization Code Flow ativado;
- PKCE obrigatório com `S256`;
- Implicit Flow e Direct Access Grants desativados;
- exige redirect URIs e web origins explícitos;
- pode receber audiences de um ou mais microserviços gerenciados.

```bash
CLIENT_TYPE="web"
CLIENT_ID="ouros-web"
REDIRECT_URIS="https://app.example.com/*"
WEB_ORIGINS="https://app.example.com"
AUDIENCES="ms-example-api|ms-another-api"
```

### `service`

Representa uma identidade máquina-a-máquina, como worker, cron, automação ou integração backend.

- confidential client;
- client authentication ativada com `client-secret`;
- service account ativada;
- usa OAuth 2.0 Client Credentials;
- Standard Flow, Direct Access Grants e Implicit Flow ficam desativados;
- não possui redirect URI ou web origin;
- pode receber audiences de um ou mais microserviços gerenciados;
- o secret é gerado e armazenado pelo Keycloak, nunca no Git.

```bash
CLIENT_TYPE="service"
CLIENT_ID="ouros-worker"
AUDIENCES="ms-example-api|ms-another-api"
```

Valores múltiplos usam `|` como separador. Não use `*` em `WEB_ORIGINS`; mantenha as origens explícitas.

## Claims de identidade

O reconciliador mantém um default client scope chamado `ouros-identity` e o anexa automaticamente aos clients `mobile` e `web` gerenciados. Ele publica somente no access token/userinfo os atributos necessários para a transição do domínio legado:

| Claim | Origem | Tipo |
| --- | --- | --- |
| `database_id` | ID da linha no banco legado | `long` |
| `account_type` | `farm_owner`, `company_employee` ou `admin` | `String` |
| `farm_id` | fazenda associada, quando existir | `long` |
| `enterprise_id` | empresa associada, quando existir | `long` |
| `first_access` | estado legado do primeiro acesso, quando existir | `boolean` |

A role de autorização continua em `realm_access.roles`. O claim `sub` pertence ao Keycloak e não deve ser substituído pelo ID numérico do banco.

## Fluxo para adicionar um client

1. copie um exemplo de `iac/examples/` para `iac/resources/<client>.conf`;
2. ajuste o tipo e os campos necessários;
3. abra uma PR;
4. a CI valida sintaxe, referências, tipos, Docker e um Keycloak real de integração;
5. após merge e redeploy na Discloud, o startup reconciler aplica a configuração.

Uma mudança de client passa portanto pelo mesmo fluxo de revisão de código da infraestrutura.

## Audiences

`AUDIENCES` de clients `mobile`, `web` e `service` só pode referenciar audiences declaradas por clients `microservice` no mesmo diretório gerenciado. O reconciliador primeiro cria todos os resource servers e scopes e só depois configura os clients consumidores, então a ordem dos arquivos não importa.

Exemplo:

```bash
# ms-telemetry-dashboard-service.conf
CLIENT_TYPE="microservice"
CLIENT_ID="ms-telemetry-dashboard-service"
AUDIENCE="ms-telemetry-dashboard-service"
SCOPE_NAME="ms-telemetry-dashboard-audience"
MAPPER_NAME="ms-telemetry-dashboard-audience"
```

Um mobile, web ou service client que declare:

```bash
AUDIENCES="ms-telemetry-dashboard-service"
```

recebe `ms-telemetry-dashboard-audience` como default client scope. No access token emitido para esse client, a audience do telemetry passa a aparecer no claim `aud`.

## User Storage e service secrets

O provider `ouros-auth-service` é read-only: lookup e validação de senha passam pelo `ms-auth-service`, mas o Keycloak não altera a senha do banco legado. O client interno `keycloak-user-storage` é criado pelo IaC, recebe apenas a audience `ms-auth-service-internal` e seu secret é lido e injetado diretamente no componente User Storage durante a reconciliação. Esse secret não precisa ser copiado para Git, Infisical ou Discloud.

Para outros `CLIENT_TYPE="service"`, o Keycloak também cria e mantém o secret do confidential client. O consumidor deve obter esse valor por um canal operacional seguro e armazená-lo no secret manager do próprio serviço.

Rotacionar ou distribuir secrets é uma operação diferente da declaração estrutural do client e não deve introduzir credenciais no Git.

`client_credentials` autentica a própria aplicação. Um token emitido nesse fluxo representa a service account e não um usuário final.

## Autenticação do reconciliador

Configure um administrador permanente exclusivamente para automação na Discloud:

```env
KC_IAC_ADMIN_USERNAME=...
KC_IAC_ADMIN_PASSWORD=...
KC_IAC_REALM=ouros
```

O primeiro rollout aceita `KC_BOOTSTRAP_ADMIN_USERNAME` e `KC_BOOTSTRAP_ADMIN_PASSWORD` como fallback enquanto o administrador temporário ainda existir. Antes de remover o temporary admin, configure as credenciais permanentes do IaC.

A sessão do `kcadm` é armazenada apenas em `/tmp/keycloak-iac` dentro do container.

## Segurança e comportamento

O reconciliador é idempotente e deliberadamente não destrutivo. Clients declarados são criados ou atualizados, mas remover um arquivo `.conf` não apaga automaticamente o client já existente no Keycloak. Exclusões devem ser explícitas em uma mudança dedicada.

Arquivos em `iac/resources/` aceitam apenas declarações simples `KEY="value"`. A CI rejeita chaves desconhecidas, tipos inválidos, IDs duplicados, audiences duplicadas, scope names duplicados e referências para APIs que não estejam declaradas no IaC.

Secrets não pertencem a `iac/resources/`. Mobile e web são public clients sem secret. Services são confidential clients cujo secret vive no Keycloak/secret manager. Credenciais administrativas continuam apenas no ambiente da Discloud.

## Validação local

```bash
bash iac/validate.sh
shellcheck iac/*.sh scripts/*.sh ci/*.sh
```

Os testes de integração da CI sobem PostgreSQL + Keycloak + um auth service simulado e validam os quatro tipos de client, service JWT interno, User Storage, login federado, senha inválida, access token, refresh token, refresh grant, roles, claims de identidade e uma segunda reconciliação sem duplicações. O provider também possui testes unitários Java e cobertura JaCoCo.
