package app.ouros.keycloak.storage;

import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.storage.StorageUnavailableException;
import org.keycloak.util.JsonSerialization;

import java.util.Optional;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class OurosAuthApiClientTest {
    private MockWebServer server;
    private int clientSequence;

    @BeforeEach
    void startServer() throws Exception {
        server = new MockWebServer();
        server.start();
        clientSequence++;
    }

    @AfterEach
    void stopServer() throws Exception {
        server.shutdown();
    }

    private OurosAuthApiClient client() {
        return new OurosAuthApiClient(
                server.url("/auth/").toString(),
                server.url("/token").toString(),
                "keycloak-user-storage-" + clientSequence,
                "secret"
        );
    }

    private static String identityJson() {
        return """
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
                """;
    }

    private void enqueueToken(String value) {
        server.enqueue(new MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("{\"access_token\":\"" + value + "\",\"expires_in\":60}"));
    }

    @Test
    void findsIdentityByEmailWithServiceBearerToken() throws Exception {
        enqueueToken("service-token");
        server.enqueue(new MockResponse().setResponseCode(200).setBody(identityJson()));

        Optional<OurosIdentity> result = client().findByEmail("User+tag@example.com");

        assertTrue(result.isPresent());
        assertEquals(42L, result.orElseThrow().databaseId());

        RecordedRequest tokenRequest = server.takeRequest(1, TimeUnit.SECONDS);
        RecordedRequest lookupRequest = server.takeRequest(1, TimeUnit.SECONDS);
        assertNotNull(tokenRequest);
        assertNotNull(lookupRequest);
        assertEquals("/token", tokenRequest.getPath());
        assertEquals("Basic", tokenRequest.getHeader("Authorization").split(" ", 2)[0]);
        assertTrue(lookupRequest.getPath().startsWith(
                "/auth/internal/v1/identities/by-email?email=User%2Btag%40example.com"
        ));
        assertEquals("Bearer service-token", lookupRequest.getHeader("Authorization"));
    }

    @Test
    void reusesValidServiceTokenAcrossLookups() {
        enqueueToken("cached-token");
        server.enqueue(new MockResponse().setResponseCode(404));
        server.enqueue(new MockResponse().setResponseCode(404));

        OurosAuthApiClient client = client();
        assertTrue(client.findByEmail("one@example.com").isEmpty());
        assertTrue(client.findByExternalId("farm_owner", 999).isEmpty());

        assertEquals(3, server.getRequestCount());
    }

    @Test
    void treatsValidationAndMissingIdentityResponsesAsEmpty() {
        enqueueToken("token-422");
        server.enqueue(new MockResponse().setResponseCode(422));

        assertTrue(client().findByEmail("bad").isEmpty());
    }

    @Test
    void findsIdentityByStableExternalId() {
        enqueueToken("stable-token");
        server.enqueue(new MockResponse().setResponseCode(200).setBody(identityJson()));

        OurosIdentity identity = client()
                .findByExternalId("farm_owner", 42)
                .orElseThrow();

        assertEquals("farm_owner:42", identity.externalId());
    }

    @Test
    void invalidPasswordDoesNotRefreshServiceToken() throws Exception {
        enqueueToken("valid-service-token");
        server.enqueue(new MockResponse().setResponseCode(403));

        OurosAuthApiClient client = client();
        OurosIdentity identity = OurosIdentity.fromJson(
                JsonSerialization.mapper.readTree(identityJson())
        );

        assertFalse(client.verifyPassword(identity, "wrong-password"));
        assertEquals(2, server.getRequestCount());
    }

    @Test
    void legacyCredentialUnauthorizedWithoutBearerChallengeIsNotRetried() throws Exception {
        enqueueToken("legacy-service-token");
        server.enqueue(new MockResponse().setResponseCode(401));

        OurosAuthApiClient client = client();
        OurosIdentity identity = OurosIdentity.fromJson(
                JsonSerialization.mapper.readTree(identityJson())
        );

        assertFalse(client.verifyPassword(identity, "wrong-password"));
        assertEquals(2, server.getRequestCount());
    }

    @Test
    void bearerUnauthorizedRefreshesServiceTokenOnce() throws Exception {
        enqueueToken("expired-service-token");
        server.enqueue(new MockResponse()
                .setResponseCode(401)
                .setHeader("WWW-Authenticate", "Bearer"));
        enqueueToken("fresh-service-token");
        server.enqueue(new MockResponse().setResponseCode(200).setBody(identityJson()));

        OurosIdentity identity = client()
                .findByEmail("user@example.com")
                .orElseThrow();

        assertEquals(42L, identity.databaseId());
        assertEquals(4, server.getRequestCount());
    }

    @Test
    void validPasswordReturnsTrue() throws Exception {
        enqueueToken("password-token");
        server.enqueue(new MockResponse().setResponseCode(200).setBody(
                "{\"authenticated\":true,\"identity\":" + identityJson() + "}"
        ));

        OurosAuthApiClient client = client();
        OurosIdentity identity = OurosIdentity.fromJson(
                JsonSerialization.mapper.readTree(identityJson())
        );

        assertTrue(client.verifyPassword(identity, "correct-password"));
    }

    @Test
    void rejectsMalformedIdentityResponses() {
        enqueueToken("bad-identity-token");
        server.enqueue(new MockResponse().setResponseCode(200).setBody("{\"email\":\"x@y.z\"}"));

        assertThrows(
                StorageUnavailableException.class,
                () -> client().findByEmail("x@y.z")
        );
    }

    @Test
    void failsClosedWhenAuthServiceReturnsUnexpectedStatus() {
        enqueueToken("error-token");
        server.enqueue(new MockResponse().setResponseCode(500));

        assertThrows(
                StorageUnavailableException.class,
                () -> client().findByEmail("user@example.com")
        );
    }

    @Test
    void failsClosedOnInvalidServiceTokenResponse() {
        server.enqueue(new MockResponse()
                .setResponseCode(200)
                .setBody("{\"access_token\":\"\",\"expires_in\":60}"));

        assertThrows(
                StorageUnavailableException.class,
                () -> client().findByEmail("user@example.com")
        );
    }

    @Test
    void failsClosedWhenTokenEndpointRejectsClient() {
        server.enqueue(new MockResponse().setResponseCode(401));

        assertThrows(
                StorageUnavailableException.class,
                () -> client().findByEmail("user@example.com")
        );
    }
}
