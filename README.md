# ouros-keycloak

<!-- REPO-METADATA:START -->
<div align="center">

[![Repo Size](https://img.shields.io/github/repo-size/Ouros-App/ouros-keycloak?style=flat-square&label=REPO%20SIZE)](https://github.com/Ouros-App/ouros-keycloak)
[![Languages](https://img.shields.io/github/languages/count/Ouros-App/ouros-keycloak?style=flat-square&label=LANGUAGES)](https://github.com/Ouros-App/ouros-keycloak/languages)
[![Forks](https://img.shields.io/github/forks/Ouros-App/ouros-keycloak?style=flat-square&label=FORKS)](https://github.com/Ouros-App/ouros-keycloak/network/members)
[![Issues](https://img.shields.io/github/issues/Ouros-App/ouros-keycloak?style=flat-square&label=ISSUES)](https://github.com/Ouros-App/ouros-keycloak/issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/Ouros-App/ouros-keycloak?style=flat-square&label=PULL%20REQUESTS)](https://github.com/Ouros-App/ouros-keycloak/pulls)

</div>
<!-- REPO-METADATA:END -->

Infraestrutura de identidade do Ouros baseada em Keycloak, PostgreSQL e configuração de clients como código.

## Status e escopo

O repositório atualmente mantém:

- Keycloak 26.7.3 em produção na Discloud;
- realm `ouros` com as roles `farm_owner`, `company_employee` e `admin`;
- PostgreSQL dedicado ao Keycloak na VLAN privada da Discloud;
- endpoint público OIDC/JWKS em `https://ouros-keycloak.discloud.app`;
- realm, roles, clients, scopes e User Storage reconciliados como Infrastructure as Code no startup;
- quatro perfis de client: `microservice`, `mobile`, `web` e `service`;
- User Storage SPI read-only para autenticar identidades existentes do Ouros através do `ms-auth-service`;
- escopo gerenciado `ouros-identity` para transportar claims de negócio em access tokens de usuários;
- configuração do `ms-telemetry-dashboard-service` versionada no IaC.

O Keycloak é a autoridade que cria sessões e tokens de usuário. O `ms-auth-service` permanece responsável por consultar e validar as credenciais do banco legado através de endpoints internos autenticados. Resource servers validam JWT localmente usando issuer, audience e JWKS do realm.

## Topologia

```text
Mobile / Web
    |
    | Authorization Code + PKCE S256
    v
https://ouros-keycloak.discloud.app
    |
    | User Storage SPI
    | service JWT: aud=ms-auth-service-internal
    v
ms-auth-service /internal/v1/*
    |
    | read-only
    v
PostgreSQL de identidade legado

Keycloak
    |
    | sessão + access_token + refresh_token
    v
Mobile / Web

Microservices
    |
    | JWKS / OIDC metadata
    v
https://ouros-keycloak.discloud.app

Workers / automações
    |
    | Client Credentials
    v
https://ouros-keycloak.discloud.app
```

A aplicação Keycloak é publicada como `TYPE=site`, enquanto `VLAN=true` permite acesso ao PostgreSQL privado `keycloak-db`.

## Principais componentes

- `Dockerfile`: imagem otimizada do Keycloak e entrypoint do reconciliador IaC.
- `realm/ouros-realm.json`: bootstrap do realm e roles iniciais.
- `scripts/keycloak-entrypoint.sh`: inicia o Keycloak, aguarda a Admin API e executa a reconciliação.
- `providers/ouros-user-storage/`: provider Java 21 que implementa User Storage para identidades Ouros.
- `iac/sync-realm.sh`: reconcilia hardening do realm e as roles `farm_owner`, `company_employee` e `admin`.
- `iac/sync-clients.sh`: cria e atualiza clients, audiences e o scope `ouros-identity`.
- `iac/sync-user-storage.sh`: cria ou atualiza o componente User Storage e injeta o secret gerado pelo próprio Keycloak sem versioná-lo.
- `iac/user-storage/`: configuração declarativa do provider em produção.
- `iac/resources/`: fonte de verdade dos clients gerenciados em produção.
- `iac/examples/`: exemplos dos tipos suportados.
- `iac/test-fixtures/`: fixtures usadas nos testes de integração da CI.
- `iac/validate.sh`: validação estática das declarações e configuração de deploy.
- `discloud.config`: configuração da aplicação na Discloud.

## Pré-requisitos

Para executar ou publicar o projeto são necessários:

- Docker para build/testes locais;
- PostgreSQL dedicado ao Keycloak;
- aplicação e banco com acesso à VLAN da Discloud;
- credenciais administrativas permanentes para o reconciliador IaC após o bootstrap inicial.

## Instalação e configuração

Use `.env.example` como referência. As principais variáveis são:

| Variável | Uso |
| --- | --- |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` | Criação do administrador temporário no primeiro bootstrap. |
| `KC_IAC_ADMIN_USERNAME` / `KC_IAC_ADMIN_PASSWORD` | Administrador permanente do realm `master`, com a role de client `realm-management:realm-admin`. |
| `KC_RECOVERY_ADMIN_USERNAME` / `KC_RECOVERY_ADMIN_PASSWORD` | Uso emergencial, em par: recupera a role administrativa do IaC e remove o admin temporário ao fim do startup. |
| `KC_IAC_REALM` | Realm gerenciado pelo IaC; padrão esperado: `ouros`. |
| `KC_HOSTNAME` | URL pública do Keycloak. |
| `KC_DB_URL` | JDBC URL do PostgreSQL dedicado. |
| `KC_DB_USERNAME` | Usuário do PostgreSQL. |
| `KCRAW_DB_PASSWORD` | Senha do PostgreSQL preservando caracteres literais como `$`. |

Exemplo de produção:

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

Não configure `KC_DB_PASSWORD` junto de `KCRAW_DB_PASSWORD`.

### Recuperação de acesso administrativo

Se o usuário do IaC autenticar mas responder `HTTP 403` ao reconciliar o realm, configure **temporariamente** os dois secrets `KC_RECOVERY_ADMIN_USERNAME` e `KC_RECOVERY_ADMIN_PASSWORD` e faça um deploy. O entrypoint cria um administrador temporário no realm `master`, concede `realm-management:realm-admin` ao `KC_IAC_ADMIN_USERNAME`, executa a reconciliação com o usuário permanente e remove o administrador temporário ao final.

Os dois secrets de recuperação devem ser removidos do Infisical após o log `[keycloak-iac] reconciliation complete`. Se o startup falhar antes desse ponto, o admin temporário é mantido para permitir diagnóstico; não o reutilize como credencial permanente.

## Clients as Code

Cada client gerenciado é um arquivo `.conf` em `iac/resources/`. Alterar a configuração de identidade passa por PR, CI e redeploy.

| Tipo | Uso | Fluxos |
| --- | --- | --- |
| `microservice` | API/resource server | login desativado; cria audience scope + mapper |
| `mobile` | aplicativo nativo | Authorization Code + PKCE S256 |
| `web` | frontend web/SPA | Authorization Code + PKCE S256 + web origins explícitas |
| `service` | worker, cron, integração ou automação M2M | client confidencial + service account + Client Credentials |

Exemplo de microserviço:

```bash
CLIENT_TYPE="microservice"
CLIENT_ID="ms-example-api"
AUDIENCE="ms-example-api"
SCOPE_NAME="ms-example-api-audience"
MAPPER_NAME="ms-example-api-audience"
```

Exemplo mobile:

```bash
CLIENT_TYPE="mobile"
CLIENT_ID="ouros-mobile"
REDIRECT_URIS="com.ouros.app:/oauth2redirect"
AUDIENCES="ms-example-api|ms-another-api"
```

Exemplo web:

```bash
CLIENT_TYPE="web"
CLIENT_ID="ouros-web"
REDIRECT_URIS="https://app.example.com/*"
WEB_ORIGINS="https://app.example.com"
AUDIENCES="ms-example-api|ms-another-api"
```

Exemplo service:

```bash
CLIENT_TYPE="service"
CLIENT_ID="ouros-worker"
AUDIENCES="ms-example-api|ms-another-api"
```

Clients `service` são confidenciais. O Keycloak gera e mantém o client secret; ele não é versionado no repositório. `AUDIENCES` de `mobile`, `web` e `service` só pode apontar para audiences declaradas por clients `microservice`. Valores múltiplos usam `|` como separador.

Todo client `mobile` ou `web` gerenciado recebe também o default client scope `ouros-identity`. Em tokens de usuário ele mapeia `database_id`, `account_type`, `farm_id`, `enterprise_id` e `first_access`. Campos opcionais ausentes não são inventados. A autorização principal continua em `realm_access.roles`, enquanto `sub` identifica o sujeito federado do Keycloak.

O reconciliador é idempotente e não destrutivo: remover um arquivo do Git não apaga automaticamente o client já existente no Keycloak. Consulte [`iac/README.md`](iac/README.md) para o contrato completo.

## Deploy

A Discloud usa:

```ini
NAME=Ouros Keycloak
ID=ouros-keycloak
TYPE=site
MAIN=Dockerfile
RAM=2048
VERSION=latest
AUTORESTART=true
VLAN=true
```

No startup, o container executa a sequência:

```text
Keycloak
  -> aguarda Admin API
  -> autentica kcadm
  -> reconcilia realm + roles
  -> reconcilia clients + scopes
  -> reconcilia User Storage
  -> mantém o processo principal ativo
```

Para adicionar ou alterar um client em produção, abra uma PR alterando `iac/resources/`, aguarde a CI e redeploye a aplicação após o merge.

## Endpoints OIDC

Issuer:

```text
https://ouros-keycloak.discloud.app/realms/ouros
```

Discovery:

```text
https://ouros-keycloak.discloud.app/realms/ouros/.well-known/openid-configuration
```

JWKS:

```text
https://ouros-keycloak.discloud.app/realms/ouros/protocol/openid-connect/certs
```

Resource servers devem validar assinatura, `iss`, `exp` e `aud` antes de confiar nos claims.

## Testes e qualidade

Validação local:

```bash
bash iac/validate.sh
shellcheck iac/*.sh scripts/*.sh ci/*.sh
docker build -t ouros-keycloak:test .
```

A CI valida:

- sintaxe Bash e ShellCheck;
- `realm/ouros-realm.json`;
- contrato do `discloud.config`;
- schema das declarações IaC;
- duplicidade de IDs, audiences e scope names;
- referências `AUDIENCES` entre aplicações/services e microserviços;
- regras de redirect URI e web origins;
- ausência de secrets versionados;
- build real do Dockerfile;
- integração PostgreSQL + Keycloak;
- reconciliação dos tipos `microservice`, `mobile`, `web` e `service`;
- PKCE S256, redirect URIs, web origins e audience scopes;
- fluxo real `client_credentials` e audience do token de `service`;
- login real de usuário federado, senha inválida e emissão de access + refresh token;
- uso real do refresh token e preservação de `sub`, role e claims de negócio;
- presença e tipos dos claims `database_id`, `account_type`, `farm_id` e `first_access`;
- testes unitários Java do provider com JUnit, Mockito e MockWebServer;
- cobertura JaCoCo importada no SonarCloud;
- idempotência da reconciliação de realm, clients, scopes e User Storage;
- disponibilidade do JWKS;
- SonarCloud e CodeQL.

## Estrutura do projeto

```text
.
├── .github/workflows/ci-cd.yml
├── Dockerfile
├── discloud.config
├── realm/
│   └── ouros-realm.json
├── scripts/
│   └── keycloak-entrypoint.sh
├── ci/
│   └── keycloak-integration.sh
└── iac/
    ├── README.md
    ├── validate.sh
    ├── validate-user-storage.sh
    ├── sync-realm.sh
    ├── sync-clients.sh
    ├── sync-user-storage.sh
    ├── user-storage/
    │   └── ouros-auth-service.conf
    ├── resources/
    │   ├── keycloak-user-storage.conf
    │   ├── ms-auth-service-internal.conf
    │   └── ms-telemetry-dashboard-service.conf
    ├── examples/
    │   ├── microservice.conf.example
    │   ├── mobile.conf.example
    │   ├── web.conf.example
    │   └── service.conf.example
    └── test-fixtures/
        ├── ci-api.conf
        ├── ci-mobile.conf
        ├── ci-web.conf
        └── ci-service.conf
```

## Segurança

- credenciais e client secrets nunca devem ser commitados;
- PostgreSQL permanece somente na VLAN privada;
- acessos públicos ao Keycloak usam HTTPS;
- mobile e web são public clients com PKCE, sem client secret;
- services são confidential clients, com secret gerado pelo Keycloak e service account habilitada;
- Direct Access Grants e Implicit Flow permanecem desativados;
- a sessão administrativa do `kcadm` fica apenas em `/tmp/keycloak-iac`;
- `client_credentials` representa identidade de serviço e nunca identidade de usuário;
- a comunicação Keycloak → `ms-auth-service` exige service JWT com issuer, audience e `azp` esperados;
- senhas continuam no identity store legado e não podem ser sobrescritas pelo Keycloak;
- `sub` é a identidade de autenticação estável do Keycloak; `database_id` é o ID legado usado quando a regra de negócio precisa referenciar a linha original.

## Licença

Este projeto está sob a licença MIT, conforme o arquivo [LICENSE](LICENSE).
