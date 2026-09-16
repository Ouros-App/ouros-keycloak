# ouros-keycloak

Infraestrutura de identidade centralizada do Ouros usando Keycloak.

## Objetivo atual

Este repositório publica o Keycloak em `https://ouros-keycloak.discloud.app` para fornecer OIDC/JWKS de forma estável aos serviços do Ouros, enquanto o PostgreSQL do Keycloak permanece acessível apenas pela VLAN privada da Discloud.

O cliente/mobile não precisa usar endpoints administrativos do Keycloak. O `ms-auth-service` continua sendo o ponto de entrada da aplicação para login e gerenciamento de identidade, enquanto os demais serviços podem validar JWT diretamente usando os endpoints públicos do realm.

## Stack

- Keycloak 26.7.3
- PostgreSQL dedicado ao Keycloak
- Deploy na Discloud via Dockerfile
- Realm inicial: `ouros`
- URL pública: `https://ouros-keycloak.discloud.app`
- Banco acessível pela VLAN privada da Discloud
- clients/resource servers gerenciados como código via `kcadm.sh`

## Topologia

```text
Mobile / Web
    |
    | HTTPS
    v
ms-auth-service
    |
    | HTTPS / OIDC
    v
https://ouros-keycloak.discloud.app
    |
    | VLAN privada
    v
keycloak-db:5432

Telemetry / Spring / MCP
    |
    | HTTPS / JWKS
    v
https://ouros-keycloak.discloud.app
```

O Keycloak é publicado como `TYPE=site` e usa `ID=ouros-keycloak`, mas continua com `VLAN=true` para alcançar o banco privado `keycloak-db`. A VLAN não impede a rota pública do site; ela é usada para a comunicação interna com o PostgreSQL.

## Estrutura

```text
.
├── Dockerfile
├── discloud.config
├── .env.example
├── iac/
│   ├── README.md
│   ├── sync-clients.sh
│   └── resources/
│       └── ms-telemetry-dashboard-service.conf
├── scripts/
│   └── keycloak-entrypoint.sh
└── realm/
    └── ouros-realm.json
```

## Realm inicial

O realm `ouros` é importado automaticamente no primeiro boot e contém as roles iniciais:

- `farm_owner`
- `company_employee`
- `admin`

## Clients as Code

Os clients das APIs não precisam mais ser cadastrados manualmente no Admin Console. No startup, o container sobe o Keycloak, aguarda a Admin API local e executa o reconciliador em `iac/sync-clients.sh`.

Cada API gerenciada possui um arquivo declarativo em `iac/resources/`. Exemplo:

```bash
CLIENT_ID="ms-example-api"
AUDIENCE="ms-example-api"
SCOPE_NAME="ms-example-api-audience"
MAPPER_NAME="ms-example-api-audience"
```

O deploy cria ou atualiza automaticamente:

- o client OIDC da API com flows de login desativados;
- o client scope de audience;
- o Audience Protocol Mapper;
- o vínculo do scope como default no client.

Para adicionar uma nova API ao Keycloak, adicione o arquivo em `iac/resources/`, abra uma PR e redeploye após o merge. O processo é idempotente e não remove clients automaticamente quando um arquivo é apagado, evitando exclusões acidentais.

A configuração atual do `ms-telemetry-dashboard-service` já está versionada em `iac/resources/ms-telemetry-dashboard-service.conf`. Mais detalhes estão em [`iac/README.md`](iac/README.md).

### Contrato OIDC do telemetry

- client id: `ms-telemetry-dashboard-service`
- audience no access token: `ms-telemetry-dashboard-service`
- issuer: `https://ouros-keycloak.discloud.app/realms/ouros`

O resource server deve validar explicitamente assinatura/JWKS, `iss`, `exp` e `aud`.

> O client que efetivamente obtiver o token do usuário também precisará receber/solicitar o audience scope adequado conforme o fluxo final do `ms-auth-service`. `client_credentials` continua representando identidade de serviço, não de usuário.

## Variáveis de ambiente

Configure na Discloud:

```env
KC_BOOTSTRAP_ADMIN_USERNAME=...
KC_BOOTSTRAP_ADMIN_PASSWORD=...

KC_IAC_ADMIN_USERNAME=...
KC_IAC_ADMIN_PASSWORD=...
KC_IAC_REALM=ouros

KC_HOSTNAME=https://ouros-keycloak.discloud.app
KC_DB_URL=jdbc:postgresql://keycloak-db:5432/keycloak
KC_DB_USERNAME=keycloak
KCRAW_DB_PASSWORD=...
```

`KC_IAC_ADMIN_USERNAME` e `KC_IAC_ADMIN_PASSWORD` devem apontar para um administrador permanente usado pelo reconciliador. No primeiro rollout, o script aceita as credenciais bootstrap como fallback para facilitar a migração, mas as credenciais permanentes devem ser configuradas antes da remoção do temporary admin.

O banco do Keycloak deve ser dedicado à identidade e permanecer acessível apenas pela VLAN da Discloud.

Para a senha do PostgreSQL, prefira `KCRAW_DB_PASSWORD`. Esse formato preserva valores literais, inclusive senhas contendo `$`, `$$` ou `${...}`. Não defina `KC_DB_PASSWORD` e `KCRAW_DB_PASSWORD` ao mesmo tempo.

## Segurança

- nunca commitar credenciais reais;
- manter o PostgreSQL do Keycloak somente na VLAN privada;
- usar HTTPS para todos os acessos públicos ao Keycloak;
- manter credenciais administrativas restritas ao `ms-auth-service`, ao reconciliador IaC e aos operadores autorizados;
- executar o container do Keycloak como usuário não-root;
- validar assinatura, `iss`, `aud` e expiração dos JWTs;
- não confiar em `user_id` enviado pelo cliente quando o `sub` autenticado puder ser usado.
