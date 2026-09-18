package app.ouros.keycloak.storage;

import org.junit.jupiter.api.Test;
import org.keycloak.util.JsonSerialization;

import static org.junit.jupiter.api.Assertions.*;

class OurosIdentityTest {

    @Test
    void parsesCompleteIdentityAndBuildsExternalId() throws Exception {
        OurosIdentity identity = OurosIdentity.fromJson(JsonSerialization.mapper.readTree("""
                {
                  "id": 42,
                  "email": "user@example.com",
                  "account_type": "farm_owner",
                  "realm_role": "farm_owner",
                  "name": "Maria da Silva",
                  "farm_id": 7,
                  "enterprise_id": null,
                  "first_access": false
                }
                """));

        assertEquals(42L, identity.databaseId());
        assertEquals("user@example.com", identity.email());
        assertEquals("farm_owner", identity.accountType());
        assertEquals("farm_owner", identity.realmRole());
        assertEquals("Maria da Silva", identity.name());
        assertEquals(7L, identity.farmId());
        assertNull(identity.enterpriseId());
        assertFalse(identity.firstAccess());
        assertEquals("farm_owner:42", identity.externalId());
        assertEquals("Maria", identity.firstName());
        assertEquals("da Silva", identity.lastName());
    }

    @Test
    void derivesProfileNameFromEmailWhenLegacyNameIsMissing() throws Exception {
        OurosIdentity identity = OurosIdentity.fromJson(JsonSerialization.mapper.readTree("""
                {
                  "id": 9,
                  "email": "admin.ouros@example.com",
                  "account_type": "admin",
                  "realm_role": "admin"
                }
                """));

        assertEquals("admin", identity.firstName());
        assertEquals("ouros", identity.lastName());
        assertNull(identity.farmId());
        assertNull(identity.enterpriseId());
        assertNull(identity.firstAccess());
    }

    @Test
    void duplicatesSingleTokenNameSoKeycloakProfileIsComplete() throws Exception {
        OurosIdentity identity = OurosIdentity.fromJson(JsonSerialization.mapper.readTree("""
                {
                  "id": 3,
                  "email": "neo@example.com",
                  "account_type": "admin",
                  "realm_role": "admin",
                  "name": "Neo"
                }
                """));

        assertEquals("Neo", identity.firstName());
        assertEquals("Neo", identity.lastName());
    }

    @Test
    void normalizesWhitespaceInLegacyName() throws Exception {
        OurosIdentity identity = OurosIdentity.fromJson(JsonSerialization.mapper.readTree("""
                {
                  "id": 8,
                  "email": "user@example.com",
                  "account_type": "company_employee",
                  "realm_role": "company_employee",
                  "name": "  Ana   Maria  "
                }
                """));

        assertEquals("Ana", identity.firstName());
        assertEquals("Maria", identity.lastName());
    }

    @Test
    void rejectsMissingOrInvalidId() throws Exception {
        var missing = JsonSerialization.mapper.readTree("""
                {"email":"a@b.com","account_type":"admin","realm_role":"admin"}
                """);
        var textId = JsonSerialization.mapper.readTree("""
                {"id":"1","email":"a@b.com","account_type":"admin","realm_role":"admin"}
                """);

        assertThrows(IllegalArgumentException.class, () -> OurosIdentity.fromJson(missing));
        assertThrows(IllegalArgumentException.class, () -> OurosIdentity.fromJson(textId));
    }

    @Test
    void rejectsBlankRequiredFields() throws Exception {
        var blankEmail = JsonSerialization.mapper.readTree("""
                {"id":1,"email":" ","account_type":"admin","realm_role":"admin"}
                """);

        IllegalArgumentException error = assertThrows(
                IllegalArgumentException.class,
                () -> OurosIdentity.fromJson(blankEmail)
        );
        assertTrue(error.getMessage().contains("email"));
    }
}
