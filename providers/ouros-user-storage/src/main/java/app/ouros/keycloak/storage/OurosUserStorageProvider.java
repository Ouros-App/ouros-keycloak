package app.ouros.keycloak.storage;

import org.keycloak.component.ComponentModel;
import org.keycloak.credential.CredentialInput;
import org.keycloak.credential.CredentialInputUpdater;
import org.keycloak.credential.CredentialInputValidator;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.storage.ReadOnlyException;
import org.keycloak.storage.StorageId;
import org.keycloak.storage.UserStorageProvider;
import org.keycloak.storage.user.UserLookupProvider;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Stream;

public final class OurosUserStorageProvider implements
        UserStorageProvider,
        UserLookupProvider,
        CredentialInputValidator,
        CredentialInputUpdater {

    private final KeycloakSession session;
    private final ComponentModel model;
    private final OurosAuthApiClient client;
    private final Map<String, UserModel> loadedUsers = new HashMap<>();

    OurosUserStorageProvider(KeycloakSession session, ComponentModel model, OurosAuthApiClient client) {
        this.session = session;
        this.model = model;
        this.client = client;
    }

    @Override
    public UserModel getUserById(RealmModel realm, String id) {
        UserModel cached = loadedUsers.get(id);
        if (cached != null) {
            return cached;
        }

        ExternalIdentityKey key = ExternalIdentityKey.parse(new StorageId(id).getExternalId());
        if (key == null) {
            return null;
        }

        return client.findByExternalId(key.accountType(), key.databaseId())
                .map(identity -> adapt(realm, identity))
                .orElse(null);
    }

    @Override
    public UserModel getUserByUsername(RealmModel realm, String username) {
        return findByEmail(realm, username);
    }

    @Override
    public UserModel getUserByEmail(RealmModel realm, String email) {
        return findByEmail(realm, email);
    }

    private UserModel findByEmail(RealmModel realm, String email) {
        if (email == null || email.isBlank()) {
            return null;
        }

        String cacheKey = "email:" + email.strip().toLowerCase();
        UserModel cached = loadedUsers.get(cacheKey);
        if (cached != null) {
            return cached;
        }

        Optional<OurosIdentity> identity = client.findByEmail(email);
        return identity.map(value -> adapt(realm, value)).orElse(null);
    }

    private UserModel adapt(RealmModel realm, OurosIdentity identity) {
        OurosUserAdapter user = new OurosUserAdapter(session, realm, model, identity);
        loadedUsers.put(user.getId(), user);
        loadedUsers.put("email:" + identity.email().strip().toLowerCase(), user);
        return user;
    }

    @Override
    public boolean supportsCredentialType(String credentialType) {
        return PasswordCredentialModel.TYPE.equals(credentialType);
    }

    @Override
    public boolean isConfiguredFor(RealmModel realm, UserModel user, String credentialType) {
        return supportsCredentialType(credentialType);
    }

    @Override
    public boolean isValid(RealmModel realm, UserModel user, CredentialInput credentialInput) {
        if (!supportsCredentialType(credentialInput.getType())) {
            return false;
        }
        String password = credentialInput.getChallengeResponse();
        if (password == null) {
            return false;
        }

        OurosIdentity identity = resolveIdentity(user);
        return identity != null && client.verifyPassword(identity, password);
    }

    private OurosIdentity resolveIdentity(UserModel user) {
        if (user instanceof OurosUserAdapter adapter) {
            return adapter.identity();
        }
        ExternalIdentityKey key = ExternalIdentityKey.parse(new StorageId(user.getId()).getExternalId());
        if (key == null) {
            return null;
        }
        return client.findByExternalId(key.accountType(), key.databaseId()).orElse(null);
    }

    @Override
    public boolean updateCredential(RealmModel realm, UserModel user, CredentialInput input) {
        throw new ReadOnlyException("Ouros credentials are managed by the production identity store.");
    }

    @Override
    public void disableCredentialType(RealmModel realm, UserModel user, String credentialType) {
        throw new ReadOnlyException("Ouros credentials are read-only in Keycloak.");
    }

    @Override
    public Stream<String> getDisableableCredentialTypesStream(RealmModel realm, UserModel user) {
        return Stream.empty();
    }

    @Override
    public void close() {
        loadedUsers.clear();
    }

    private record ExternalIdentityKey(String accountType, long databaseId) {
        static ExternalIdentityKey parse(String value) {
            if (value == null) {
                return null;
            }
            String[] parts = value.split(":", 2);
            if (parts.length != 2 || parts[0].isBlank()) {
                return null;
            }
            try {
                return new ExternalIdentityKey(parts[0], Long.parseLong(parts[1]));
            } catch (NumberFormatException exception) {
                return null;
            }
        }
    }
}
