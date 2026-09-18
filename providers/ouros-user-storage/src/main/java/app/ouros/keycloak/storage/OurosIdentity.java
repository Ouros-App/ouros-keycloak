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

    private OurosIdentity(JsonNode node) {
        JsonNode id = node.get("id");
        if (id == null || !id.isIntegralNumber() || !id.canConvertToLong()) {
            throw new IllegalArgumentException("Missing or invalid identity field: id");
        }

        this.databaseId = id.longValue();
        this.email = requiredText(node, "email");
        this.accountType = requiredText(node, "account_type");
        this.realmRole = requiredText(node, "realm_role");
        this.name = nullableText(node, "name");
        this.farmId = nullableLong(node, "farm_id");
        this.enterpriseId = nullableLong(node, "enterprise_id");
        this.firstAccess = nullableBoolean(node, "first_access");
    }

    static OurosIdentity fromJson(JsonNode node) {
        return new OurosIdentity(node);
    }

    private static String requiredText(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull() || !value.isTextual() || value.textValue().isBlank()) {
            throw new IllegalArgumentException("Missing or invalid identity field: " + field);
        }
        return value.textValue();
    }

    private static String nullableText(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        if (!value.isTextual()) {
            throw new IllegalArgumentException("Invalid identity field: " + field);
        }
        return value.textValue();
    }

    private static Long nullableLong(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        if (!value.isIntegralNumber() || !value.canConvertToLong()) {
            throw new IllegalArgumentException("Invalid identity field: " + field);
        }
        return value.longValue();
    }

    private static Boolean nullableBoolean(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        if (!value.isBoolean()) {
            throw new IllegalArgumentException("Invalid identity field: " + field);
        }
        return value.booleanValue();
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
