package app.ouros.keycloak.storage;

import com.fasterxml.jackson.databind.JsonNode;

final class OurosIdentity {
    private final long databaseId;
    private final String email;
    private final String accountType;
    private final String realmRole;
    private final String name;
    private final Long farmId;
    private final Long enterpriseId;
    private final Boolean firstAccess;

    private OurosIdentity(long databaseId, String email, String accountType, String realmRole,
                          String name, Long farmId, Long enterpriseId, Boolean firstAccess) {
        this.databaseId = databaseId;
        this.email = email;
        this.accountType = accountType;
        this.realmRole = realmRole;
        this.name = name;
        this.farmId = farmId;
        this.enterpriseId = enterpriseId;
        this.firstAccess = firstAccess;
    }

    static OurosIdentity fromJson(JsonNode node) {
        JsonNode id = node.get("id");
        if (id == null || !id.isIntegralNumber() || !id.canConvertToLong()) {
            throw new IllegalArgumentException("Missing or invalid identity field: id");
        }

        return new OurosIdentity(
                id.longValue(),
                requiredText(node, "email"),
                requiredText(node, "account_type"),
                requiredText(node, "realm_role"),
                nullableText(node, "name"),
                nullableLong(node, "farm_id"),
                nullableLong(node, "enterprise_id"),
                nullableBoolean(node, "first_access")
        );
    }

    private static String requiredText(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull() || value.asText().isBlank()) {
            throw new IllegalArgumentException("Missing identity field: " + field);
        }
        return value.asText();
    }

    private static String nullableText(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value == null || value.isNull() ? null : value.asText();
    }

    private static Long nullableLong(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value == null || value.isNull() ? null : value.asLong();
    }

    private static Boolean nullableBoolean(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value == null || value.isNull() ? null : value.asBoolean();
    }

    long databaseId() { return databaseId; }
    String email() { return email; }
    String accountType() { return accountType; }
    String realmRole() { return realmRole; }
    String name() { return name; }
    Long farmId() { return farmId; }
    Long enterpriseId() { return enterpriseId; }
    Boolean firstAccess() { return firstAccess; }
    String externalId() { return accountType + ":" + databaseId; }

    String firstName() {
        return profileName().firstName();
    }

    String lastName() {
        return profileName().lastName();
    }

    private ProfileName profileName() {
        String normalized = name;
        if (normalized == null || normalized.isBlank()) {
            String localPart = email.split("@", 2)[0];
            normalized = localPart.replaceAll("[._-]+", " ");
        }
        normalized = normalized == null ? "" : normalized.trim().replaceAll("\\s+", " ");
        if (normalized.isBlank()) {
            normalized = "Ouros";
        }

        int separator = normalized.indexOf(' ');
        if (separator < 0) {
            return new ProfileName(normalized, normalized);
        }
        return new ProfileName(
                normalized.substring(0, separator),
                normalized.substring(separator + 1)
        );
    }

    private record ProfileName(String firstName, String lastName) {}
}
