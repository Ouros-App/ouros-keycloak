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
- perfis declarativos de client para `microservice`, `mobile`, `web`, `service` e grants restritos de debug;
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
| `KC_IAC_ADMIN_USERNAME` / `KC_IAC_ADMIN_PASSWORD` | Administrador permanente do realm `master`, com a realm role `admin`. |
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

Se o usuário do IaC autenticar mas responder `HTTP 403` ao reconciliar o realm, configure **temporariamente** os dois secrets `KC_RECOVERY_ADMIN_USERNAME` e `KC_RECOVERY_ADMIN_PASSWORD` e faça um deploy. O entrypoint cria um administrador temporário no realm `master`, concede a realm role `admin` ao `KC_IAC_ADMIN_USERNAME`, executa a reconciliação com o usuário permanente e remove o administrador temporário ao final.

Mantenha os mesmos dois secrets de recuperação até o log `[keycloak-iac] reconciliation complete`; se uma tentativa falhar após criar o admin temporário, o próximo startup reutiliza essa conta em vez de tentar criá-la novamente. Depois da conclusão, remova os dois secrets do Infisical. Se o startup falhar antes desse ponto, o admin temporário é mantido para permitir diagnóstico; não o reutilize como credencial permanente.

## Clients as Code

Cada client gerenciado é um arquivo `.conf` em `iac/resources/`. Alterar a configuração de identidade passa por PR, CI e redeploy.

| Tipo | Uso | Fluxos |
| --- | --- | --- |
| `microservice` | API/resource server | login desativado; cria audience scope + mapper |
| `mobile` | aplicativo nativo | Authorization Code + PKCE S256 |
| `web` | frontend web/SPA | Authorization Code + PKCE S256 + web origins explícitas |
| `service` | worker, cron, integração ou automação M2M | client confidencial + service account + Client Credentials |
| `password-grant` | ferramenta interna/debug explicitamente isolada | client confidencial + Direct Access Grant, sem Browser Flow |

Exemplo de microserviço:

```bash
CLIENT_TYPE="microservice"
CLIENT_ID="ms-example-api"
AUDIENCE="ms-example-api"
SCOPE_NAME="ms-example-api-audience"
MAPPER_NAME="ms-example-api-audience"
```

Client mobile de produção:

```bash
CLIENT_TYPE="mobile"
CLIENT_ID="ouros-mobile"
REDIRECT_URIS="com.ourosapp.ourosandroidapp:/oauth2redirect|http://127.0.0.1:8765/callback"
AUDIENCES="ms-spring-api|ms-ai-server|ms-telemetry-dashboard-service|ms-mcp-server-ouros-knowledge"
```

O app autentica uma única vez via Authorization Code + PKCE S256. O access token pode ser enviado como Bearer para as três APIs mobile-facing. Ele também inclui a audience interna `ms-mcp-server-ouros-knowledge`, porque o AI Server encaminha o mesmo JWT ao Knowledge MCP durante chamadas do Midas. O refresh token é enviado somente ao endpoint de token do Keycloak. O redirect loopback em `127.0.0.1:8765` existe apenas para o script operacional de teste E2E; o Android usa o custom scheme.

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

Clients `service` são confidenciais. Clients `password-grant` também são confidenciais, mas existem somente para exceções internas explicitamente declaradas. O caso atual é `ms-ai-server-debug`, destinado ao Debug Console do AI Server e limitado aos audiences `ms-ai-server` e `ms-mcp-server-ouros-knowledge`, pois o AI Server encaminha o mesmo JWT autenticado ao MCP padrão. O Keycloak gera e mantém o client secret; ele não é versionado no repositório. `AUDIENCES` de `mobile`, `web` e `service` só pode apontar para audiences declaradas por clients `microservice`. Valores múltiplos usam `|` como separador.

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

## Email OTP e Mailpit local

O fluxo interativo de Browser / Authorization Code + PKCE pode exigir um segundo fator por e-mail através do authenticator `ouros-email-otp`. Ele é opt-in e só é reconciliado quando `OUROS_EMAIL_OTP_ENABLED=true`.

Para desenvolvimento, suba o Mailpit somente quando precisar testar entrega de e-mail:

```bash
docker compose -f docker-compose.mailpit.yml up -d
```

A UI fica em `http://127.0.0.1:8025` e o SMTP em `127.0.0.1:1025`. Endereços fake do banco funcionam normalmente porque o Mailpit captura a mensagem localmente e não tenta entregá-la na internet.

Exemplo de configuração local quando o Keycloak consegue alcançar o host:

```env
OUROS_SMTP_HOST=host.docker.internal
OUROS_SMTP_PORT=1025
OUROS_SMTP_AUTH=false
OUROS_SMTP_STARTTLS=false
OUROS_SMTP_SSL=false
OUROS_EMAIL_OTP_ENABLED=true
OUROS_EMAIL_OTP_HMAC_SECRET=<segredo-aleatorio-de-pelo-menos-32-bytes>
```

O segredo HMAC deve ficar no secret manager e nunca no Git. O digest do OTP é protegido com HMAC-SHA-256 e o desafio é armazenado no armazenamento single-use do Keycloak, que garante consumo único mesmo em concorrência entre nós.

Se o realm já usa um browser flow customizado, configure `OUROS_EMAIL_OTP_FALLBACK_BROWSER_FLOW` com o alias exato desse flow antes de habilitar o OTP. Assim, desabilitar `OUROS_EMAIL_OTP_ENABLED` restaura o flow correto em vez de assumir `browser`.

Se Keycloak e Mailpit estiverem na mesma rede Docker, use `OUROS_SMTP_HOST=mailpit`. Não habilite o OTP sem SMTP: o reconciliador falha de forma explícita para evitar um fluxo de login impossível de concluir.

O OTP expira por padrão em 5 minutos, aceita no máximo 5 tentativas e limita reenvios a um por 30 segundos. Esses valores podem ser ajustados com `OUROS_EMAIL_OTP_TTL_SECONDS`, `OUROS_EMAIL_OTP_MAX_ATTEMPTS` e `OUROS_EMAIL_OTP_RESEND_COOLDOWN_SECONDS`.

### Smoke test E2E do mobile

Depois de reconciliar o client `ouros-mobile` e habilitar SMTP + OTP em produção, use o smoke test mantido no repositório `ouros-docs`:

```bash
python3 scripts/test-mobile-auth.py
```

O comando acima é executado a partir de um checkout do `Ouros-App/ouros-docs`.

O script usa o redirect loopback exato `http://127.0.0.1:8765/callback`, abre o Browser Flow real, espera senha + OTP no navegador, troca o authorization code com PKCE S256 e valida que o access token contém as audiences mobile-facing `ms-spring-api`, `ms-ai-server`, `ms-telemetry-dashboard-service` e a audience delegada `ms-mcp-server-ouros-knowledge`. Em seguida, usa o refresh token e valida o novo access token.

Tokens não são impressos por padrão. Para um teste manual explícito de APIs:

```bash
python3 scripts/test-mobile-auth.py --output ./mobile-auth-tokens.json
```

O arquivo é criado com permissão `0600` quando suportado e deve ser apagado após o teste.

## Segurança

- credenciais e client secrets nunca devem ser commitados;
- PostgreSQL permanece somente na VLAN privada;
- acessos públicos ao Keycloak usam HTTPS;
- mobile e web são public clients com PKCE, sem client secret;
- services são confidential clients, com secret gerado pelo Keycloak e service account habilitada;
- Direct Access Grants permanecem desativados para mobile, web, services e resource servers; a única exceção declarativa é um client `password-grant` interno e confidencial. Implicit Flow permanece desativado em todos os clients;
- a sessão administrativa do `kcadm` fica apenas em `/tmp/keycloak-iac`;
- `client_credentials` representa identidade de serviço e nunca identidade de usuário;
- a comunicação Keycloak → `ms-auth-service` exige service JWT com issuer, audience e `azp` esperados;
- senhas continuam no identity store legado e não podem ser sobrescritas pelo Keycloak;
- `sub` é a identidade de autenticação estável do Keycloak; `database_id` é o ID legado usado quando a regra de negócio precisa referenciar a linha original.

## Licença

Este projeto está sob a licença MIT, conforme o arquivo [LICENSE](LICENSE).
