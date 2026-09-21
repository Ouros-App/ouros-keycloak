package app.ouros.keycloak.otp;

import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Supplier;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;

public final class OurosEmailOtpAuthenticator implements Authenticator {
    static final String OTP_CHALLENGE_ID_NOTE = "ouros.email-otp.challenge-id";
    static final String OTP_EXPIRES_NOTE = "ouros.email-otp.expires";
    static final String OTP_SENT_AT_NOTE = "ouros.email-otp.sent-at";

    static final String CHALLENGE_DIGEST = "digest";
    static final String CHALLENGE_ATTEMPTS = "attempts";
    static final String TERMINAL_STATUS = "status";
    static final String TERMINAL_CONSUMED = "consumed";
    static final String TERMINAL_LOCKED = "locked";

    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String LOGIN_TEMPLATE = "ouros-email-otp-login.ftl";
    private static final String HMAC_ALGORITHM = "HmacSHA256";
    private static final String HMAC_SECRET_ENV = "OUROS_EMAIL_OTP_HMAC_SECRET";
    private static final int MIN_HMAC_SECRET_LENGTH = 32;
    private static final int DEFAULT_TTL_SECONDS = 300;
    private static final int DEFAULT_MAX_ATTEMPTS = 5;
    private static final int DEFAULT_RESEND_COOLDOWN_SECONDS = 30;

    private final Supplier<byte[]> hmacSecretSupplier;

    public OurosEmailOtpAuthenticator() {
        this(OurosEmailOtpAuthenticator::loadHmacSecret);
    }

    OurosEmailOtpAuthenticator(Supplier<byte[]> hmacSecretSupplier) {
        this.hmacSecretSupplier = Objects.requireNonNull(hmacSecretSupplier);
    }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        UserModel user = context.getUser();
        if (!hasUsableEmail(user)) {
            context.failureChallenge(
                AuthenticationFlowError.INVALID_USER,
                context.form().setError("ourosEmailOtpMissingEmail").createForm(LOGIN_TEMPLATE)
            );
            return;
        }

        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        long now = Instant.now().getEpochSecond();
        if (!hasLiveChallenge(context.getSession(), authSession, now) && !sendChallenge(context, now)) {
            return;
        }

        context.challenge(renderForm(context, null));
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        MultivaluedMap<String, String> form = context.getHttpRequest().getDecodedFormParameters();
        long now = Instant.now().getEpochSecond();

        if ("true".equals(form.getFirst("resend"))) {
            long sentAt = parseLong(authSession.getAuthNote(OTP_SENT_AT_NOTE), 0L);
            int cooldown = envInt(
                "OUROS_EMAIL_OTP_RESEND_COOLDOWN_SECONDS",
                DEFAULT_RESEND_COOLDOWN_SECONDS,
                1,
                300
            );
            if (now - sentAt < cooldown) {
                context.challenge(renderForm(context, "ourosEmailOtpResendTooSoon"));
                return;
            }

            discardChallenge(context.getSession(), authSession);
            if (!sendChallenge(context, now)) {
                return;
            }
            context.challenge(renderForm(context, "ourosEmailOtpResent"));
            return;
        }

        String submitted = form.getFirst("otp");
        if (submitted == null || !submitted.matches("\\d{6}")) {
            context.challenge(renderForm(context, "ourosEmailOtpInvalid"));
            return;
        }

        int maxAttempts = envInt(
            "OUROS_EMAIL_OTP_MAX_ATTEMPTS",
            DEFAULT_MAX_ATTEMPTS,
            1,
            20
        );

        ConsumeResult result;
        try {
            result = consumeChallenge(
                context.getSession(),
                authSession,
                submitted,
                now,
                maxAttempts,
                hmacSecretSupplier.get()
            );
        } catch (IllegalStateException exception) {
            context.failureChallenge(
                AuthenticationFlowError.INTERNAL_ERROR,
                context.form().setError("ourosEmailOtpConfigurationError").createForm(LOGIN_TEMPLATE)
            );
            return;
        }

        switch (result) {
            case SUCCESS -> context.success();
            case INVALID -> context.challenge(renderForm(context, "ourosEmailOtpInvalid"));
            case BUSY -> context.challenge(renderForm(context, "ourosEmailOtpConcurrentRequest"));
            case EXPIRED -> {
                discardChallenge(context.getSession(), authSession);
                if (!sendChallenge(context, now)) {
                    return;
                }
                context.challenge(renderForm(context, "ourosEmailOtpExpired"));
            }
            case TOO_MANY_ATTEMPTS -> {
                clearChallengeNotes(authSession);
                context.failureChallenge(
                    AuthenticationFlowError.INVALID_CREDENTIALS,
                    renderForm(context, "ourosEmailOtpTooManyAttempts")
                );
            }
            case ALREADY_CONSUMED -> {
                clearChallengeNotes(authSession);
                context.failureChallenge(
                    AuthenticationFlowError.INVALID_CREDENTIALS,
                    renderForm(context, "ourosEmailOtpAlreadyUsed")
                );
            }
        }
    }

    private boolean sendChallenge(AuthenticationFlowContext context, long now) {
        UserModel user = context.getUser();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        KeycloakSession session = context.getSession();

        byte[] secret;
        try {
            secret = hmacSecretSupplier.get();
        } catch (IllegalStateException exception) {
            context.failureChallenge(
                AuthenticationFlowError.INTERNAL_ERROR,
                context.form().setError("ourosEmailOtpConfigurationError").createForm(LOGIN_TEMPLATE)
            );
            return false;
        }

        discardChallenge(session, authSession);

        String code = generateCode();
        String challengeId = UUID.randomUUID().toString();
        int ttlSeconds = envInt("OUROS_EMAIL_OTP_TTL_SECONDS", DEFAULT_TTL_SECONDS, 60, 900);
        long expiresAt = now + ttlSeconds;

        Map<String, String> challengeState = new HashMap<>();
        challengeState.put(CHALLENGE_DIGEST, hmacDigest(authSession, challengeId, code, secret));
        challengeState.put(CHALLENGE_ATTEMPTS, "0");

        session.singleUseObjects().put(challengeStoreKey(challengeId), ttlSeconds, challengeState);
        authSession.setAuthNote(OTP_CHALLENGE_ID_NOTE, challengeId);
        authSession.setAuthNote(OTP_EXPIRES_NOTE, Long.toString(expiresAt));
        authSession.setAuthNote(OTP_SENT_AT_NOTE, Long.toString(now));

        Map<String, Object> attributes = new HashMap<>();
        attributes.put("code", code);
        attributes.put("ttlMinutes", Math.max(1, (ttlSeconds + 59) / 60));

        try {
            session.getProvider(EmailTemplateProvider.class)
                .setRealm(context.getRealm())
                .setUser(user)
                .setAuthenticationSession(authSession)
                .send("ourosEmailOtpSubject", "ouros-email-otp.ftl", attributes);
            return true;
        } catch (EmailException exception) {
            discardChallenge(session, authSession);
            context.failureChallenge(
                AuthenticationFlowError.INTERNAL_ERROR,
                context.form().setError("ourosEmailOtpDeliveryError").createForm(LOGIN_TEMPLATE)
            );
            return false;
        }
    }

    static ConsumeResult consumeChallenge(
        KeycloakSession session,
        AuthenticationSessionModel authSession,
        String submittedCode,
        long now,
        int maxAttempts,
        byte[] secret
    ) {
        String challengeId = authSession.getAuthNote(OTP_CHALLENGE_ID_NOTE);
        long expiresAt = parseLong(authSession.getAuthNote(OTP_EXPIRES_NOTE), 0L);

        if (challengeId == null || challengeId.isBlank()) {
            return ConsumeResult.EXPIRED;
        }

        SingleUseObjectProvider store = session.singleUseObjects();
        String storeKey = challengeStoreKey(challengeId);
        String terminalKey = terminalStoreKey(challengeId);

        Map<String, String> state = store.remove(storeKey);
        if (state == null) {
            Map<String, String> terminal = store.get(terminalKey);
            if (terminal != null) {
                return TERMINAL_LOCKED.equals(terminal.get(TERMINAL_STATUS))
                    ? ConsumeResult.TOO_MANY_ATTEMPTS
                    : ConsumeResult.ALREADY_CONSUMED;
            }
            return expiresAt <= now ? ConsumeResult.EXPIRED : ConsumeResult.BUSY;
        }

        long remainingTtl = expiresAt - now;
        if (remainingTtl <= 0) {
            return ConsumeResult.EXPIRED;
        }

        String expectedDigest = state.get(CHALLENGE_DIGEST);
        if (expectedDigest == null || !constantTimeEquals(
            expectedDigest,
            hmacDigest(authSession, challengeId, submittedCode, secret)
        )) {
            int attempts = (int) parseLong(state.get(CHALLENGE_ATTEMPTS), 0L) + 1;
            if (attempts >= maxAttempts) {
                store.put(
                    terminalKey,
                    Math.max(1L, remainingTtl),
                    Map.of(TERMINAL_STATUS, TERMINAL_LOCKED)
                );
                return ConsumeResult.TOO_MANY_ATTEMPTS;
            }

            state.put(CHALLENGE_ATTEMPTS, Integer.toString(attempts));
            store.put(storeKey, Math.max(1L, remainingTtl), state);
            return ConsumeResult.INVALID;
        }

        store.put(
            terminalKey,
            Math.max(1L, remainingTtl),
            Map.of(TERMINAL_STATUS, TERMINAL_CONSUMED)
        );
        clearChallengeNotes(authSession);
        return ConsumeResult.SUCCESS;
    }

    private static Response renderForm(AuthenticationFlowContext context, String messageKey) {
        var form = context.form()
            .setAttribute("maskedEmail", maskEmail(context.getUser() == null ? null : context.getUser().getEmail()));
        if (messageKey != null) {
            form.setError(messageKey);
        }
        return form.createForm(LOGIN_TEMPLATE);
    }

    static boolean hasUsableEmail(UserModel user) {
        return user != null && user.getEmail() != null && !user.getEmail().isBlank();
    }

    static String generateCode() {
        return String.format(Locale.ROOT, "%06d", RANDOM.nextInt(1_000_000));
    }

    static boolean hasLiveChallenge(
        KeycloakSession session,
        AuthenticationSessionModel authSession,
        long now
    ) {
        String challengeId = authSession.getAuthNote(OTP_CHALLENGE_ID_NOTE);
        long expiresAt = parseLong(authSession.getAuthNote(OTP_EXPIRES_NOTE), 0L);
        return challengeId != null
            && !challengeId.isBlank()
            && expiresAt > now
            && session.singleUseObjects().get(challengeStoreKey(challengeId)) != null;
    }

    static String hmacDigest(
        AuthenticationSessionModel authSession,
        String challengeId,
        String code,
        byte[] secret
    ) {
        if (secret == null || secret.length < MIN_HMAC_SECRET_LENGTH) {
            throw new IllegalStateException(HMAC_SECRET_ENV + " must contain at least 32 bytes");
        }

        String binding = String.join(
            ":",
            nullToEmpty(authSession.getParentSession().getId()),
            nullToEmpty(authSession.getTabId()),
            challengeId,
            code
        );

        try {
            Mac mac = Mac.getInstance(HMAC_ALGORITHM);
            mac.init(new SecretKeySpec(secret, HMAC_ALGORITHM));
            return toHex(mac.doFinal(binding.getBytes(StandardCharsets.UTF_8)));
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException(HMAC_ALGORITHM + " is unavailable", exception);
        }
    }

    static boolean constantTimeEquals(String expected, String actual) {
        return MessageDigest.isEqual(
            expected.getBytes(StandardCharsets.UTF_8),
            actual.getBytes(StandardCharsets.UTF_8)
        );
    }

    static String maskEmail(String email) {
        if (email == null || email.isBlank() || !email.contains("@")) {
            return "***";
        }
        int at = email.indexOf('@');
        String local = email.substring(0, at);
        String domain = email.substring(at + 1);
        String visible = local.isEmpty() ? "*" : local.substring(0, 1);
        return visible + "***@" + domain;
    }

    static long parseLong(String value, long fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException exception) {
            return fallback;
        }
    }

    static int envInt(String name, int fallback, int min, int max) {
        String raw = System.getenv(name);
        if (raw == null || raw.isBlank()) {
            return fallback;
        }
        try {
            int parsed = Integer.parseInt(raw);
            return Math.max(min, Math.min(max, parsed));
        } catch (NumberFormatException exception) {
            return fallback;
        }
    }

    private static byte[] loadHmacSecret() {
        String raw = System.getenv(HMAC_SECRET_ENV);
        if (raw == null || raw.isBlank()) {
            throw new IllegalStateException(HMAC_SECRET_ENV + " is required");
        }
        byte[] secret = raw.getBytes(StandardCharsets.UTF_8);
        if (secret.length < MIN_HMAC_SECRET_LENGTH) {
            throw new IllegalStateException(HMAC_SECRET_ENV + " must contain at least 32 bytes");
        }
        return secret;
    }

    private static String challengeStoreKey(String challengeId) {
        return "ouros-email-otp:" + challengeId;
    }

    private static String terminalStoreKey(String challengeId) {
        return challengeStoreKey(challengeId) + ":terminal";
    }

    private static void discardChallenge(
        KeycloakSession session,
        AuthenticationSessionModel authSession
    ) {
        String challengeId = authSession.getAuthNote(OTP_CHALLENGE_ID_NOTE);
        if (challengeId != null && !challengeId.isBlank()) {
            session.singleUseObjects().remove(challengeStoreKey(challengeId));
            session.singleUseObjects().remove(terminalStoreKey(challengeId));
        }
        clearChallengeNotes(authSession);
    }

    private static void clearChallengeNotes(AuthenticationSessionModel authSession) {
        authSession.removeAuthNote(OTP_CHALLENGE_ID_NOTE);
        authSession.removeAuthNote(OTP_EXPIRES_NOTE);
        authSession.removeAuthNote(OTP_SENT_AT_NOTE);
    }

    private static String toHex(byte[] bytes) {
        StringBuilder builder = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            builder.append(Character.forDigit((value >>> 4) & 0xF, 16));
            builder.append(Character.forDigit(value & 0xF, 16));
        }
        return builder.toString();
    }

    private static String nullToEmpty(String value) {
        return value == null ? "" : value;
    }

    enum ConsumeResult {
        SUCCESS,
        INVALID,
        BUSY,
        EXPIRED,
        TOO_MANY_ATTEMPTS,
        ALREADY_CONSUMED
    }

    @Override
    public boolean requiresUser() {
        return true;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return hasUsableEmail(user);
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {
        // No per-user enrollment is required for email OTP.
    }

    @Override
    public void close() {
        // Stateless provider.
    }
}
