package app.ouros.keycloak.storage;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.component.ComponentModel;
import org.keycloak.credential.CredentialInput;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.storage.ReadOnlyException;
import org.keycloak.util.JsonSerialization;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class OurosUserStorageProviderTest {
    private KeycloakSession session;
    private RealmModel realm;
    private ComponentModel model;
    private OurosAuthApiClient client;
    private OurosIdentity identity;
    private OurosUserStorageProvider provider;

    @BeforeEach
    void setUp() throws Exception {
        session = mock(KeycloakSession.class);
        realm = mock(RealmModel.class);
        model = mock(ComponentModel.class);
        client = mock(OurosAuthApiClient.class);
        when(model.getId()).thenReturn("provider-id");

        identity = OurosIdentity.fromJson(JsonSerialization.mapper.readTree("""
                {
                  "id": 42,
                  "email": "user@example.com",
                  "account_type": "farm_owner",
                  "realm_role": "farm_owner",
                  "name": "User Test",
                  "farm_id": 7,
                  "enterprise_id": null,
                  "first_access": false
                }
                """));
        provider = new OurosUserStorageProvider(session, model, client);
    }

    @Test
    void looksUpAndCachesUsersByEmailAndUsername() {
        when(client.findByEmail("user@example.com")).thenReturn(Optional.of(identity));

        UserModel first = provider.getUserByEmail(realm, "user@example.com");
        UserModel second = provider.getUserByUsername(realm, "user@example.com");

        assertNotNull(first);
        assertSame(first, second);
        verify(client, times(1)).findByEmail("user@example.com");
    }

    @Test
    void rejectsBlankEmailWithoutRemoteLookup() {
        assertNull(provider.getUserByEmail(realm, " "));
        assertNull(provider.getUserByUsername(realm, null));
        verifyNoInteractions(client);
    }

    @Test
    void resolvesNonCachedFederatedUserByStableId() {
        when(client.findByEmail("user@example.com")).thenReturn(Optional.of(identity));
        UserModel existing = provider.getUserByEmail(realm, "user@example.com");

        OurosUserStorageProvider fresh = new OurosUserStorageProvider(session, model, client);
        when(client.findByExternalId("farm_owner", 42)).thenReturn(Optional.of(identity));

        UserModel resolved = fresh.getUserById(realm, existing.getId());

        assertNotNull(resolved);
        assertEquals("user@example.com", resolved.getEmail());
        verify(client).findByExternalId("farm_owner", 42);
    }

    @Test
    void returnsNullForMalformedOrMissingExternalIdentity() {
        assertNull(provider.getUserById(realm, "not-a-federated-id"));

        String validStorageId = "f:provider-id:admin:999";
        when(client.findByExternalId("admin", 999)).thenReturn(Optional.empty());
        assertNull(provider.getUserById(realm, validStorageId));
    }

    @Test
    void validatesPasswordCredentialsThroughAuthService() {
        when(client.findByEmail("user@example.com")).thenReturn(Optional.of(identity));
        OurosUserAdapter user = (OurosUserAdapter) provider.getUserByEmail(
                realm,
                "user@example.com"
        );
        CredentialInput credential = mock(CredentialInput.class);
        when(credential.getType()).thenReturn(PasswordCredentialModel.TYPE);
        when(credential.getChallengeResponse()).thenReturn("password");
        when(client.verifyPassword(identity, "password")).thenReturn(true);

        assertTrue(provider.supportsCredentialType(PasswordCredentialModel.TYPE));
        assertTrue(provider.isConfiguredFor(realm, user, PasswordCredentialModel.TYPE));
        assertTrue(provider.isValid(realm, user, credential));
    }

    @Test
    void rejectsUnsupportedAndMissingCredentialChallenges() {
        CredentialInput unsupported = mock(CredentialInput.class);
        when(unsupported.getType()).thenReturn("otp");
        assertFalse(provider.isValid(realm, mock(UserModel.class), unsupported));

        CredentialInput missing = mock(CredentialInput.class);
        when(missing.getType()).thenReturn(PasswordCredentialModel.TYPE);
        when(missing.getChallengeResponse()).thenReturn(null);
        assertFalse(provider.isValid(realm, mock(UserModel.class), missing));
    }

    @Test
    void resolvesIdentityForNonAdapterUserBeforePasswordValidation() {
        CredentialInput credential = mock(CredentialInput.class);
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn("f:provider-id:farm_owner:42");
        when(credential.getType()).thenReturn(PasswordCredentialModel.TYPE);
        when(credential.getChallengeResponse()).thenReturn("password");
        when(client.findByExternalId("farm_owner", 42)).thenReturn(Optional.of(identity));
        when(client.verifyPassword(identity, "password")).thenReturn(true);

        assertTrue(provider.isValid(realm, user, credential));
    }

    @Test
    void staysReadOnlyForCredentialMutation() {
        UserModel user = mock(UserModel.class);
        CredentialInput credential = mock(CredentialInput.class);

        assertThrows(
                ReadOnlyException.class,
                () -> provider.updateCredential(realm, user, credential)
        );
        assertThrows(
                ReadOnlyException.class,
                () -> provider.disableCredentialType(realm, user, PasswordCredentialModel.TYPE)
        );
        assertTrue(provider.getDisableableCredentialTypesStream(realm, user).toList().isEmpty());
    }

    @Test
    void closeDropsPerRequestUserCache() {
        when(client.findByEmail("user@example.com")).thenReturn(Optional.of(identity));

        assertNotNull(provider.getUserByEmail(realm, "user@example.com"));
        provider.close();
        assertNotNull(provider.getUserByEmail(realm, "user@example.com"));

        verify(client, times(2)).findByEmail("user@example.com");
    }
}
