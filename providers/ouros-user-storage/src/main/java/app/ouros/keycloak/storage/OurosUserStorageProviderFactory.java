package app.ouros.keycloak.storage;

import org.keycloak.component.ComponentModel;
import org.keycloak.component.ComponentValidationException;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.storage.UserStorageProviderFactory;

import java.util.List;

public final class OurosUserStorageProviderFactory
        implements UserStorageProviderFactory<OurosUserStorageProvider> {

    static final String PROVIDER_ID = "ouros-auth-service";
    static final String AUTH_SERVICE_URL = "authServiceUrl";
    static final String TOKEN_URL = "tokenUrl";
    static final String SERVICE_CLIENT_ID = "serviceClientId";
    static final String SERVICE_CLIENT_SECRET = "serviceClientSecret";

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES = List.of(
            new ProviderConfigProperty(
                    AUTH_SERVICE_URL, "Auth service URL",
                    "Base URL of the Ouros authentication service.",
                    ProviderConfigProperty.URL_TYPE,
                    "https://ms-auth-service.discloud.app", false, true
            ),
            new ProviderConfigProperty(
                    TOKEN_URL, "Keycloak token URL",
                    "Internal token endpoint used for the managed service account.",
                    ProviderConfigProperty.URL_TYPE,
                    "http://127.0.0.1:8080/realms/ouros/protocol/openid-connect/token", false, true
            ),
            new ProviderConfigProperty(
                    SERVICE_CLIENT_ID, "Service client ID",
                    "Managed confidential client used by this provider.",
                    ProviderConfigProperty.STRING_TYPE,
                    "keycloak-user-storage", false, true
            ),
            new ProviderConfigProperty(
                    SERVICE_CLIENT_SECRET, "Service client secret",
                    "Managed by Ouros IaC. Do not copy this value outside Keycloak.",
                    ProviderConfigProperty.PASSWORD,
                    null, true, true
            )
    );

    @Override
    public OurosUserStorageProvider create(KeycloakSession session, ComponentModel model) {
        return new OurosUserStorageProvider(
                session,
                model,
                new OurosAuthApiClient(
                        required(model, AUTH_SERVICE_URL),
                        required(model, TOKEN_URL),
                        required(model, SERVICE_CLIENT_ID),
                        required(model, SERVICE_CLIENT_SECRET)
                )
        );
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getHelpText() {
        return "Read-only Ouros users authenticated by ms-auth-service.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    public void validateConfiguration(KeycloakSession session, RealmModel realm, ComponentModel config) {
        for (String key : List.of(
                AUTH_SERVICE_URL,
                TOKEN_URL,
                SERVICE_CLIENT_ID,
                SERVICE_CLIENT_SECRET
        )) {
            required(config, key);
        }
    }

    private static String required(ComponentModel model, String key) {
        String value = model.getConfig().getFirst(key);
        if (value == null || value.isBlank()) {
            throw new ComponentValidationException("Missing required setting: " + key);
        }
        return value;
    }
}
