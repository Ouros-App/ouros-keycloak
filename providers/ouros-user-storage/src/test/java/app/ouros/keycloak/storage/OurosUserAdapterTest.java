package app.ouros.keycloak.storage;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.component.ComponentModel;
import org.keycloak.models.*;
import org.keycloak.storage.ReadOnlyException;
import org.keycloak.util.JsonSerialization;

import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class OurosUserAdapterTest {
    private KeycloakSession session;
    private RealmModel realm;
    private ComponentModel model;
    private RoleModel defaultRole;
    private RoleModel managedRole;
    private OurosIdentity identity;
    private OurosUserAdapter adapter;

    @BeforeEach
    void setUp() throws Exception {
        session = mock(KeycloakSession.class);
        realm = mock(RealmModel.class);
        model = mock(ComponentModel.class);
        defaultRole = mock(RoleModel.class);
        managedRole = mock(RoleModel.class);

        when(model.getId()).thenReturn("provider-id");
        when(realm.getDefaultRole()).thenReturn(defaultRole);
        when(defaultRole.getCompositesStream()).thenReturn(Stream.empty());
        when(realm.getRole("farm_owner")).thenReturn(managedRole);

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
        adapter = new OurosUserAdapter(session, realm, model, identity);
    }

    @Test
    void exposesStableFederatedIdentityAndProfile() {
        assertEquals("f:provider-id:farm_owner:42", adapter.getId());
        assertEquals("user@example.com", adapter.getUsername());
        assertEquals("user@example.com", adapter.getEmail());
        assertFalse(adapter.isEmailVerified());
        assertEquals("User", adapter.getFirstName());
        assertEquals("Test", adapter.getLastName());
        assertSame(identity, adapter.identity());
    }

    @Test
    void exposesReadOnlyBusinessAttributes() {
        Map<String, List<String>> attributes = adapter.getAttributes();

        assertEquals(List.of("42"), attributes.get(OurosUserAdapter.DATABASE_ID));
        assertEquals(List.of("farm_owner"), attributes.get(OurosUserAdapter.ACCOUNT_TYPE));
        assertEquals(List.of("farm_owner"), attributes.get(OurosUserAdapter.REALM_ROLE));
        assertEquals(List.of("7"), attributes.get(OurosUserAdapter.FARM_ID));
        assertFalse(attributes.containsKey(OurosUserAdapter.ENTERPRISE_ID));
        assertEquals(List.of("false"), attributes.get(OurosUserAdapter.FIRST_ACCESS));
        assertEquals("42", adapter.getFirstAttribute(OurosUserAdapter.DATABASE_ID));
        assertNull(adapter.getFirstAttribute("missing"));
        assertEquals(List.of("farm_owner"), adapter.getAttributeStream(
                OurosUserAdapter.REALM_ROLE
        ).toList());
    }

    @Test
    void addsManagedRealmRoleWithoutDroppingDefaults() {
        List<RoleModel> roles = adapter.getRoleMappingsStream().toList();
        assertEquals(List.of(managedRole), roles);
    }

    @Test
    void omitsManagedRoleWhenRealmRoleDoesNotExist() {
        when(realm.getRole("farm_owner")).thenReturn(null);
        assertTrue(adapter.getRoleMappingsStream().toList().isEmpty());
    }

    @Test
    void allowsOnlyVerifyProfileCleanupForReadOnlyUsers() {
        assertDoesNotThrow(() -> adapter.removeRequiredAction("VERIFY_PROFILE"));
        assertDoesNotThrow(() -> adapter.removeRequiredAction(UserModel.RequiredAction.VERIFY_PROFILE));

        assertThrows(
                ReadOnlyException.class,
                () -> adapter.removeRequiredAction("UPDATE_PASSWORD")
        );
        assertThrows(
                ReadOnlyException.class,
                () -> adapter.removeRequiredAction(UserModel.RequiredAction.UPDATE_PASSWORD)
        );
    }

    @Test
    void delegatesCredentialManagerToKeycloakUserProvider() {
        UserProvider users = mock(UserProvider.class);
        UserCredentialManager manager = mock(UserCredentialManager.class);
        when(session.users()).thenReturn(users);
        when(users.getUserCredentialManager(adapter)).thenReturn(manager);

        assertSame(manager, adapter.credentialManager());
    }
}
