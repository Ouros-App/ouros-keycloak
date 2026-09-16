# ouros-keycloak

Infraestrutura de identidade centralizada do Ouros usando Keycloak.

## Objetivo atual

Este repositório mantém o Keycloak como serviço interno da VLAN da Discloud. O cliente/mobile não acessa o Keycloak diretamente: o `ms-auth-service` atua como ponto de entrada público para autenticação e emissão/renovação de tokens.

## Stack

- Keycloak 26.7.3
- PostgreSQL dedicado ao Keycloak
- Deploy na Discloud via Dockerfile
- Realm inicial: `ouros`
- Comunicação interna pela VLAN da Discloud

## Topologia

```text
Mobile / Web
    |
    | HTTPS
    v
ms-auth-service
    |
    | VLAN privada
    v
ouros-keycloak:8080
    |
    | VLAN privada
    v
keycloak-db:5432
```

O Keycloak não deve receber rota pública da Discloud. O `discloud.config` usa `TYPE=bot` para manter o processo fora do roteamento público de sites e `VLAN=true` para permitir comunicação interna.

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
- issuer esperado: `http://ouros-keycloak:8080/realms/ouros`

No Keycloak, configure um client scope chamado `telemetry-audience` com um **Audience Protocol Mapper** adicionando `ms-telemetry-dashboard-service` ao claim `aud`. Associe esse client scope aos clients que emitirão access tokens usados para chamar o telemetry service. O serviço deve validar explicitamente `iss`, `exp`, assinatura e `aud`.

Se os resource servers carregarem as chaves pelo endpoint JWKS, eles também precisam ter acesso à VLAN privada do Keycloak. O `ms-auth-service` é o único serviço que deve usar endpoints administrativos, de login, refresh ou gerenciamento de usuários; os demais serviços devem acessar no máximo os endpoints públicos do realm necessários para validar JWT.

## Variáveis de ambiente

Configure na Discloud:

```env
KC_BOOTSTRAP_ADMIN_USERNAME=...
KC_BOOTSTRAP_ADMIN_PASSWORD=...
KC_HOSTNAME=http://ouros-keycloak:8080
KC_DB_URL=jdbc:postgresql://keycloak-db:5432/keycloak
KC_DB_USERNAME=keycloak
KCRAW_DB_PASSWORD=...
```

O banco do Keycloak deve ser dedicado à identidade e permanecer acessível apenas pela VLAN da Discloud.

Para a senha do PostgreSQL, prefira `KCRAW_DB_PASSWORD`. Esse formato preserva valores literais, inclusive senhas contendo `$`, `$$` ou `${...}`. Não defina `KC_DB_PASSWORD` e `KCRAW_DB_PASSWORD` ao mesmo tempo.

## Segurança

- nunca commitar credenciais reais;
- não criar domínio ou rota pública para o Keycloak;
- manter Keycloak e PostgreSQL na VLAN privada da Discloud;
- expor publicamente apenas o `ms-auth-service`;
- executar o container do Keycloak como usuário não-root;
- restringir credenciais administrativas ao `ms-auth-service`;
- validar assinatura, `iss`, `aud` e expiração dos JWTs;
- não confiar em `user_id` enviado pelo cliente quando o `sub` autenticado puder ser usado.
