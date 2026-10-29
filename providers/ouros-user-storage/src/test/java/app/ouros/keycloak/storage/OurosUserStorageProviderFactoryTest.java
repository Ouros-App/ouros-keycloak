package app.ouros.keycloak.storage;

import org.junit.jupiter.api.Test;
import org.keycloak.common.util.MultivaluedHashMap;
import org.keycloak.component.ComponentModel;
import org.keycloak.component.ComponentValidationException;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class OurosUserStorageProviderFactoryTest {

    private static ComponentModel configuredModel(boolean includeSecret) {
        ComponentModel model = mock(ComponentModel.class);
        MultivaluedHashMap<String, String> config = new MultivaluedHashMap<>();
        config.add(OurosUserStorageProviderFactory.AUTH_SERVICE_URL, "https://auth.example");
        config.add(OurosUserStorageProviderFactory.TOKEN_URL, "https://keycloak.example/token");
        config.add(OurosUserStorageProviderFactory.SERVICE_CLIENT_ID, "storage-client");
        if (includeSecret) {
            config.add(OurosUserStorageProviderFactory.SERVICE_CLIENT_SECRET, "secret");
        }
        when(model.getConfig()).thenReturn(config);
        return model;
    }

    @Test
    void exposesProviderMetadataAndConfigurationSchema() {
        OurosUserStorageProviderFactory factory = new OurosUserStorageProviderFactory();

        assertEquals("ouros-auth-service", factory.getId());
        assertTrue(factory.getHelpText().contains("Read-only"));
        assertEquals(4, factory.getConfigProperties().size());
    }

    @Test
    void acceptsCompleteConfigurationAndCreatesProvider() {
        OurosUserStorageProviderFactory factory = new OurosUserStorageProviderFactory();
        ComponentModel model = configuredModel(true);
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);

        assertDoesNotThrow(() -> factory.validateConfiguration(session, realm, model));
        assertNotNull(factory.create(session, model));
    }

    @Test
    void rejectsMissingServiceClientSecret() {
        OurosUserStorageProviderFactory factory = new OurosUserStorageProviderFactory();
        ComponentModel model = configuredModel(false);

        ComponentValidationException error = assertThrows(
                ComponentValidationException.class,
                () -> factory.validateConfiguration(
                        mock(KeycloakSession.class),
                        mock(RealmModel.class),
                        model
                )
        );
        assertTrue(error.getMessage().contains(
                OurosUserStorageProviderFactory.SERVICE_CLIENT_SECRET
        ));
    }
}
