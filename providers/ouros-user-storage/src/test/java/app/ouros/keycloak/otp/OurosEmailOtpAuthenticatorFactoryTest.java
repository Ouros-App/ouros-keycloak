package app.ouros.keycloak.otp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

import org.junit.jupiter.api.Test;
import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

class OurosEmailOtpAuthenticatorFactoryTest {
    @Test
    void exposesStableProviderMetadataAndSingleton() {
        OurosEmailOtpAuthenticatorFactory factory = new OurosEmailOtpAuthenticatorFactory();
        KeycloakSession session = mock(KeycloakSession.class);

        Authenticator first = factory.create(session);
        Authenticator second = factory.create(session);

        assertSame(first, second);
        assertEquals(OurosEmailOtpAuthenticatorFactory.PROVIDER_ID, factory.getId());
        assertEquals("Ouros Email OTP", factory.getDisplayType());
        assertEquals("email-otp", factory.getReferenceCategory());
        assertFalse(factory.isConfigurable());
        assertFalse(factory.isUserSetupAllowed());
        assertTrue(factory.getHelpText().contains("one-time code"));
        assertTrue(factory.getConfigProperties().isEmpty());
    }

    @Test
    void requirementChoicesAreDefensiveCopies() {
        OurosEmailOtpAuthenticatorFactory factory = new OurosEmailOtpAuthenticatorFactory();

        AuthenticationExecutionModel.Requirement[] first = factory.getRequirementChoices();
        AuthenticationExecutionModel.Requirement[] second = factory.getRequirementChoices();

        assertNotSame(first, second);
        assertEquals(AuthenticationExecutionModel.Requirement.REQUIRED, first[0]);
        assertEquals(AuthenticationExecutionModel.Requirement.DISABLED, first[1]);

        factory.init(mock(Config.Scope.class));
        factory.postInit(mock(KeycloakSessionFactory.class));
        factory.close();
    }
}
