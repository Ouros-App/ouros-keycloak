FROM quay.io/keycloak/keycloak:26.7.3 AS builder

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.7.3

COPY --from=builder --chown=1000:0 /opt/keycloak/ /opt/keycloak/
COPY --chown=1000:0 realm/ /opt/keycloak/data/import/
COPY --chown=1000:0 iac/ /opt/keycloak/iac/
COPY --chown=1000:0 scripts/ /opt/keycloak/scripts/

ENV KC_DB=postgres
ENV KC_HTTP_ENABLED=true
ENV KC_HTTP_PORT=8080
ENV KC_PROXY_HEADERS=xforwarded
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

EXPOSE 8080

USER 1000

ENTRYPOINT ["/bin/bash", "/opt/keycloak/scripts/keycloak-entrypoint.sh"]
