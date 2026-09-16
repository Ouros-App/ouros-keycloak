# ouros-keycloak

Infraestrutura de identidade centralizada do Ouros usando Keycloak.

## Objetivo atual

Este repositório começa como um piloto isolado para autenticar o `ms-telemetry-dashboard-service` via OIDC/JWT. A migração dos demais microserviços e da API Spring só deve acontecer depois que esse fluxo estiver validado.

## Stack

- Keycloak 26.7.3
- PostgreSQL dedicado ao Keycloak
- Deploy na Discloud via Dockerfile
- Realm inicial: `ouros`

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
- issuer esperado: `https://<host-publico>/realms/ouros`

No Keycloak, configure um client scope chamado `telemetry-audience` com um **Audience Protocol Mapper** adicionando `ms-telemetry-dashboard-service` ao claim `aud`. Associe esse client scope aos clients que emitirão access tokens usados para chamar o telemetry service. O serviço deve validar explicitamente `iss`, `exp`, assinatura e `aud`.

O client scope não contém segredo e pode ser criado manualmente no console durante o piloto. Client secrets, quando existirem, permanecem fora do repositório.

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

O banco do Keycloak deve ser dedicado à identidade. Ele não deve usar as tabelas do banco de produção do Ouros.

Para a senha do PostgreSQL, prefira `KCRAW_DB_PASSWORD`. Esse formato preserva valores literais, inclusive senhas contendo `$`, `$$` ou `${...}`. Não defina `KC_DB_PASSWORD` e `KCRAW_DB_PASSWORD` ao mesmo tempo, pois o Keycloak rejeita configurações duplicadas para a mesma chave.

## Fluxo do piloto

```text
Cliente de teste
     |
     | login OIDC
     v
  Keycloak
     |
     | JWT
     v
ms-telemetry-dashboard-service
     |
     | valida assinatura/JWKS + issuer + exp + audience
     v
claims do usuário (`sub`, roles, etc.)
```

O `ms-telemetry-dashboard-service` não precisa acessar o banco de produção para autenticar o usuário.

## Migração de usuários

A primeira etapa da migração no banco de produção adiciona um `keycloak_user_id` nullable às tabelas de usuários existentes. Esse valor corresponde ao claim `sub` emitido pelo Keycloak.

Durante o piloto, o login legado permanece funcionando e nenhuma coluna `password` é removida.

## Segurança

- nunca commitar credenciais reais;
- usar PostgreSQL separado para o Keycloak;
- manter o PostgreSQL acessível apenas pela VLAN privada da Discloud;
- expor o Keycloak somente por HTTPS;
- executar o container do Keycloak como usuário não-root;
- validar JWT localmente nos serviços usando as chaves públicas/JWKS do realm;
- validar `issuer`, `audience` e expiração antes de confiar nos claims;
- não confiar em `user_id` enviado pelo cliente quando o `sub` autenticado puder ser usado.
