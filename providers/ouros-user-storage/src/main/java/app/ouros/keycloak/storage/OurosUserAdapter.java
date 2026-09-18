package app.ouros.keycloak.storage;

import org.keycloak.component.ComponentModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserCredentialManager;
import org.keycloak.models.UserModel;
import org.keycloak.storage.ReadOnlyException;
import org.keycloak.storage.StorageId;
import org.keycloak.storage.adapter.AbstractUserAdapter;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.stream.Stream;

final class OurosUserAdapter extends AbstractUserAdapter {
    static final String DATABASE_ID = "database_id";
    static final String ACCOUNT_TYPE = "account_type";
    static final String REALM_ROLE = "realm_role";
    static final String FARM_ID = "farm_id";
    static final String ENTERPRISE_ID = "enterprise_id";
    static final String FIRST_ACCESS = "first_access";

    private final OurosIdentity identity;

    OurosUserAdapter(KeycloakSession session, RealmModel realm,
                     ComponentModel storageProviderModel, OurosIdentity identity) {
        super(session, realm, storageProviderModel);
        this.identity = identity;
    }

    OurosIdentity identity() {
        return identity;
    }

    @Override
    public String getId() {
        return StorageId.keycloakId(storageProviderModel, identity.externalId());
    }

    @Override
    public UserCredentialManager credentialManager() {
        return session.users().getUserCredentialManager(this);
    }

    @Override
    public void removeRequiredAction(String action) {
        if (UserModel.RequiredAction.VERIFY_PROFILE.name().equals(action)) {
            return;
        }
        throw new ReadOnlyException("Ouros users are read-only for required-action updates.");
    }

    @Override
    public void removeRequiredAction(UserModel.RequiredAction action) {
        if (action == UserModel.RequiredAction.VERIFY_PROFILE) {
            return;
        }
        throw new ReadOnlyException("Ouros users are read-only for required-action updates.");
    }

    @Override
    public String getUsername() {
        return identity.email();
    }

    @Override
    public String getEmail() {
        return identity.email();
    }

    @Override
    public boolean isEmailVerified() {
        return false;
    }

    @Override
    public String getFirstName() {
        return identity.firstName();
    }

    @Override
    public String getLastName() {
        return identity.lastName();
    }

    @Override
    public Map<String, List<String>> getAttributes() {
        Map<String, List<String>> attributes = new LinkedHashMap<>();
        attributes.put("username", List.of(identity.email()));
        attributes.put("email", List.of(identity.email()));
        attributes.put("firstName", List.of(identity.firstName()));
        attributes.put("lastName", List.of(identity.lastName()));
        put(attributes, DATABASE_ID, Long.toString(identity.databaseId()));
        put(attributes, ACCOUNT_TYPE, identity.accountType());
        put(attributes, REALM_ROLE, identity.realmRole());
        put(attributes, FARM_ID, asString(identity.farmId()));
        put(attributes, ENTERPRISE_ID, asString(identity.enterpriseId()));
        put(attributes, FIRST_ACCESS, asString(identity.firstAccess()));
        return attributes;
    }

    @Override
    public String getFirstAttribute(String name) {
        List<String> values = getAttributes().get(name);
        return values == null || values.isEmpty() ? null : values.get(0);
    }

    @Override
    public Stream<String> getAttributeStream(String name) {
        List<String> values = getAttributes().get(name);
        return values == null ? Stream.empty() : values.stream();
    }

    @Override
    public Stream<RoleModel> getRealmRoleMappingsStream() {
        return Stream.concat(super.getRealmRoleMappingsStream(), managedRealmRole()).distinct();
    }

    @Override
    public Stream<RoleModel> getRoleMappingsStream() {
        return Stream.concat(super.getRoleMappingsStream(), managedRealmRole()).distinct();
    }

    private Stream<RoleModel> managedRealmRole() {
        RoleModel role = realm.getRole(identity.realmRole());
        return role == null ? Stream.empty() : Stream.of(role);
    }

    private static void put(Map<String, List<String>> attributes, String name, String value) {
        if (value != null && !value.isBlank()) {
            attributes.put(name, List.of(value));
        }
    }

    private static String asString(Object value) {
        return Objects.toString(value, null);
    }
}
