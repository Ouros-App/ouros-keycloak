package app.ouros.keycloak.storage;

import com.fasterxml.jackson.databind.JsonNode;
import org.keycloak.storage.StorageUnavailableException;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

final class OurosAuthApiClient {
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);
    private static final Duration TOKEN_SAFETY_MARGIN = Duration.ofSeconds(15);
    private static final String APPLICATION_JSON = "application/json";
    private static final Map<String, CachedToken> TOKEN_CACHE = new ConcurrentHashMap<>();

    private final HttpClient httpClient;
    private final String authServiceUrl;
    private final String tokenUrl;
    private final String serviceClientId;
    private final String serviceClientSecret;
    private final String tokenCacheKey;

    OurosAuthApiClient(String authServiceUrl, String tokenUrl,
                       String serviceClientId, String serviceClientSecret) {
        this.httpClient = HttpClient.newBuilder().connectTimeout(REQUEST_TIMEOUT).build();
        this.authServiceUrl = stripTrailingSlash(authServiceUrl);
        this.tokenUrl = tokenUrl;
        this.serviceClientId = serviceClientId;
        this.serviceClientSecret = serviceClientSecret;
        this.tokenCacheKey = this.authServiceUrl + "\u0000" + tokenUrl + "\u0000" + serviceClientId;
    }

    Optional<OurosIdentity> findByEmail(String email) {
        String encodedEmail = URLEncoder.encode(email, StandardCharsets.UTF_8);
        HttpResponse<String> response = sendWithServiceToken(
                "GET",
                authServiceUrl + "/internal/v1/identities/by-email?email=" + encodedEmail,
                null
        );
        if (response.statusCode() == 404 || response.statusCode() == 422) {
            return Optional.empty();
        }
        requireStatus(response, 200, "identity lookup");
        return Optional.of(parseIdentity(response.body()));
    }

    Optional<OurosIdentity> findByExternalId(String accountType, long databaseId) {
        HttpResponse<String> response = sendWithServiceToken(
                "GET",
                authServiceUrl + "/internal/v1/identities/" + accountType + "/" + databaseId,
                null
        );
        if (response.statusCode() == 404) {
            return Optional.empty();
        }
        requireStatus(response, 200, "identity lookup");
        return Optional.of(parseIdentity(response.body()));
    }

    boolean verifyPassword(OurosIdentity identity, String password) {
        try {
            String body = JsonSerialization.writeValueAsString(Map.of(
                    "email", identity.email(),
                    "password", password,
                    "account_type", identity.accountType()
            ));
            HttpResponse<String> response = sendWithServiceToken(
                    "POST",
                    authServiceUrl + "/internal/v1/credentials/verify",
                    body
            );
            if (response.statusCode() == 401 || response.statusCode() == 403) {
                return false;
            }
            requireStatus(response, 200, "credential verification");
            return true;
        } catch (IOException exception) {
            throw new StorageUnavailableException("Could not serialize credential request", exception);
        }
    }

    private HttpResponse<String> sendWithServiceToken(String method, String url, String body) {
        String token = getServiceToken();
        HttpResponse<String> response = send(method, url, body, token);
        if (isBearerAuthenticationFailure(response)) {
            TOKEN_CACHE.remove(tokenCacheKey);
            token = getServiceToken();
            response = send(method, url, body, token);
        }
        return response;
    }

    private static boolean isBearerAuthenticationFailure(HttpResponse<?> response) {
        if (response.statusCode() != 401) {
            return false;
        }
        return response.headers()
                .firstValue("WWW-Authenticate")
                .map(value -> value.toLowerCase().contains("bearer"))
                .orElse(false);
    }

    private HttpResponse<String> send(String method, String url, String body, String bearerToken) {
        try {
            HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(url))
                    .timeout(REQUEST_TIMEOUT)
                    .header("Accept", APPLICATION_JSON)
                    .header("Authorization", "Bearer " + bearerToken);

            if (body == null) {
                request.method(method, HttpRequest.BodyPublishers.noBody());
            } else {
                request.header("Content-Type", APPLICATION_JSON)
                        .method(method, HttpRequest.BodyPublishers.ofString(body));
            }

            return httpClient.send(request.build(), HttpResponse.BodyHandlers.ofString());
        } catch (IOException exception) {
            throw new StorageUnavailableException("Ouros auth service is unavailable", exception);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new StorageUnavailableException("Interrupted while calling Ouros auth service", exception);
        } catch (IllegalArgumentException exception) {
            throw new StorageUnavailableException("Invalid Ouros auth service URL", exception);
        }
    }

    private String getServiceToken() {
        CachedToken cached = TOKEN_CACHE.get(tokenCacheKey);
        if (cached != null && cached.isUsable()) {
            return cached.value();
        }

        synchronized (TOKEN_CACHE) {
            cached = TOKEN_CACHE.get(tokenCacheKey);
            if (cached != null && cached.isUsable()) {
                return cached.value();
            }
            CachedToken refreshed = requestServiceToken();
            TOKEN_CACHE.put(tokenCacheKey, refreshed);
            return refreshed.value();
        }
    }

    private CachedToken requestServiceToken() {
        String basic = Base64.getEncoder().encodeToString(
                (serviceClientId + ":" + serviceClientSecret).getBytes(StandardCharsets.UTF_8)
        );
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(tokenUrl))
                    .timeout(REQUEST_TIMEOUT)
                    .header("Accept", APPLICATION_JSON)
                    .header("Authorization", "Basic " + basic)
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString("grant_type=client_credentials"))
                    .build();
            HttpResponse<String> response = httpClient.send(
                    request,
                    HttpResponse.BodyHandlers.ofString()
            );
            requireStatus(response, 200, "Keycloak service-token request");

            JsonNode json = JsonSerialization.mapper.readTree(response.body());
            String accessToken = json.path("access_token").asText();
            long expiresIn = json.path("expires_in").asLong();
            if (accessToken.isBlank() || expiresIn <= 0) {
                throw new StorageUnavailableException("Keycloak returned an invalid service-token response");
            }

            Duration lifetime = Duration.ofSeconds(expiresIn);
            Duration margin = lifetime.compareTo(TOKEN_SAFETY_MARGIN) > 0
                    ? TOKEN_SAFETY_MARGIN
                    : Duration.ofSeconds(1);
            return new CachedToken(accessToken, Instant.now().plus(lifetime).minus(margin));
        } catch (IOException exception) {
            throw new StorageUnavailableException("Could not read Keycloak token response", exception);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new StorageUnavailableException("Interrupted while requesting service token", exception);
        } catch (IllegalArgumentException exception) {
            throw new StorageUnavailableException("Invalid Keycloak token URL", exception);
        }
    }

    private static OurosIdentity parseIdentity(String json) {
        try {
            return OurosIdentity.fromJson(JsonSerialization.mapper.readTree(json));
        } catch (IOException | IllegalArgumentException exception) {
            throw new StorageUnavailableException("Invalid identity response from Ouros auth service", exception);
        }
    }

    private static void requireStatus(HttpResponse<String> response, int expected, String operation) {
        if (response.statusCode() != expected) {
            throw new StorageUnavailableException(
                    operation + " failed with HTTP " + response.statusCode()
            );
        }
    }

    private static String stripTrailingSlash(String value) {
        return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
    }

    private record CachedToken(String value, Instant expiresAt) {
        boolean isUsable() {
            return Instant.now().isBefore(expiresAt);
        }
    }
}
