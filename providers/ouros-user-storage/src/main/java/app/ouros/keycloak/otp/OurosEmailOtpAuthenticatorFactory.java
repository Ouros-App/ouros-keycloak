package app.ouros.keycloak.otp;

import java.util.List;
import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;

public final class OurosEmailOtpAuthenticatorFactory implements AuthenticatorFactory {
    public static final String PROVIDER_ID = "ouros-email-otp";

    private static final OurosEmailOtpAuthenticator SINGLETON = new OurosEmailOtpAuthenticator();
    private static final AuthenticationExecutionModel.Requirement[] REQUIREMENTS = {
        AuthenticationExecutionModel.Requirement.REQUIRED,
        AuthenticationExecutionModel.Requirement.DISABLED
    };

    @Override
    public Authenticator create(KeycloakSession session) {
        return SINGLETON;
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "Ouros Email OTP";
    }

    @Override
    public String getReferenceCategory() {
        return "email-otp";
    }

    @Override
    public boolean isConfigurable() {
        return false;
    }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return REQUIREMENTS.clone();
    }

    @Override
    public boolean isUserSetupAllowed() {
        return false;
    }

    @Override
    public String getHelpText() {
        return "Sends a short-lived one-time code to the authenticated user's email address.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of();
    }

    @Override
    public void init(Config.Scope config) {
        // Runtime tuning is supplied through OUROS_EMAIL_OTP_* environment variables.
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // Nothing to initialize after startup.
    }

    @Override
    public void close() {
        // Singleton is stateless.
    }
}
