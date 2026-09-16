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
└── realm/
    └── ouros-realm.json
```

## Realm inicial

O realm `ouros` é importado automaticamente no primeiro boot e contém as roles iniciais:

- `farm_owner`
- `company_employee`
- `admin`

Clientes OIDC e segredos não são versionados neste repositório. Eles devem ser criados/configurados no Keycloak e os segredos devem ficar apenas no ambiente da Discloud ou em um gerenciador de segredos.

### Contrato OIDC do piloto

O primeiro resource server do piloto é o `ms-telemetry-dashboard-service`.

- client id esperado pelo serviço: `ms-telemetry-dashboard-service`
- audience esperada no access token: `ms-telemetry-dashboard-service`
- issuer esperado: `https://ouros-keycloak.discloud.app/realms/ouros`

No Keycloak, configure um client scope chamado `telemetry-audience` com um **Audience Protocol Mapper** adicionando `ms-telemetry-dashboard-service` ao claim `aud`. Associe esse client scope aos clients que emitirão access tokens usados para chamar o telemetry service. O serviço deve validar explicitamente `iss`, `exp`, assinatura e `aud`.

## Variáveis de ambiente

Configure na Discloud:

```env
KC_BOOTSTRAP_ADMIN_USERNAME=...
KC_BOOTSTRAP_ADMIN_PASSWORD=...
KC_HOSTNAME=https://ouros-keycloak.discloud.app
KC_DB_URL=jdbc:postgresql://keycloak-db:5432/keycloak
KC_DB_USERNAME=keycloak
KCRAW_DB_PASSWORD=...
```

O banco do Keycloak deve ser dedicado à identidade e permanecer acessível apenas pela VLAN da Discloud.

Para a senha do PostgreSQL, prefira `KCRAW_DB_PASSWORD`. Esse formato preserva valores literais, inclusive senhas contendo `$`, `$$` ou `${...}`. Não defina `KC_DB_PASSWORD` e `KCRAW_DB_PASSWORD` ao mesmo tempo.

## Segurança

- nunca commitar credenciais reais;
- manter o PostgreSQL do Keycloak somente na VLAN privada;
- usar HTTPS para todos os acessos públicos ao Keycloak;
- manter credenciais administrativas restritas ao `ms-auth-service` e aos operadores autorizados;
- executar o container do Keycloak como usuário não-root;
- validar assinatura, `iss`, `aud` e expiração dos JWTs;
- não confiar em `user_id` enviado pelo cliente quando o `sub` autenticado puder ser usado.
