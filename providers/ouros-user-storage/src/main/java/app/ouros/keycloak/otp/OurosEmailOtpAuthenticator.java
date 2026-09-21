package app.ouros.keycloak.otp;

import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

public final class OurosEmailOtpAuthenticator implements Authenticator {
    static final String OTP_HASH_NOTE = "ouros.email-otp.hash";
    static final String OTP_EXPIRES_NOTE = "ouros.email-otp.expires";
    static final String OTP_ATTEMPTS_NOTE = "ouros.email-otp.attempts";
    static final String OTP_SENT_AT_NOTE = "ouros.email-otp.sent-at";

    private static final SecureRandom RANDOM = new SecureRandom();
    private static final int DEFAULT_TTL_SECONDS = 300;
    private static final int DEFAULT_MAX_ATTEMPTS = 5;
    private static final int DEFAULT_RESEND_COOLDOWN_SECONDS = 30;

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        UserModel user = context.getUser();
        if (!hasUsableEmail(user)) {
            context.failureChallenge(
                AuthenticationFlowError.INVALID_USER,
                context.form().setError("ourosEmailOtpMissingEmail").createForm("ouros-email-otp-login.ftl")
            );
            return;
        }

        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        long now = Instant.now().getEpochSecond();
        if (!hasLiveChallenge(authSession, now)) {
            if (!sendChallenge(context, now)) {
                return;
            }
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
            int cooldown = envInt("OUROS_EMAIL_OTP_RESEND_COOLDOWN_SECONDS", DEFAULT_RESEND_COOLDOWN_SECONDS, 1, 300);
            if (now - sentAt < cooldown) {
                context.challenge(renderForm(context, "ourosEmailOtpResendTooSoon"));
                return;
            }
            clearChallenge(authSession);
            if (!sendChallenge(context, now)) {
                return;
            }
            context.challenge(renderForm(context, "ourosEmailOtpResent"));
            return;
        }

        if (!hasLiveChallenge(authSession, now)) {
            clearChallenge(authSession);
            if (!sendChallenge(context, now)) {
                return;
            }
            context.challenge(renderForm(context, "ourosEmailOtpExpired"));
            return;
        }

        String submitted = form.getFirst("otp");
        if (submitted == null || !submitted.matches("\\d{6}")) {
            context.challenge(renderForm(context, "ourosEmailOtpInvalid"));
            return;
        }

        int attempts = (int) parseLong(authSession.getAuthNote(OTP_ATTEMPTS_NOTE), 0L);
        int maxAttempts = envInt("OUROS_EMAIL_OTP_MAX_ATTEMPTS", DEFAULT_MAX_ATTEMPTS, 1, 20);

        if (!matches(authSession, submitted)) {
            attempts += 1;
            authSession.setAuthNote(OTP_ATTEMPTS_NOTE, Integer.toString(attempts));
            if (attempts >= maxAttempts) {
                clearChallenge(authSession);
                context.failureChallenge(
                    AuthenticationFlowError.INVALID_CREDENTIALS,
                    renderForm(context, "ourosEmailOtpTooManyAttempts")
                );
                return;
            }
            context.challenge(renderForm(context, "ourosEmailOtpInvalid"));
            return;
        }

        clearChallenge(authSession);
        context.success();
    }

    private boolean sendChallenge(AuthenticationFlowContext context, long now) {
        UserModel user = context.getUser();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String code = generateCode();
        int ttlSeconds = envInt("OUROS_EMAIL_OTP_TTL_SECONDS", DEFAULT_TTL_SECONDS, 60, 900);

        authSession.setAuthNote(OTP_HASH_NOTE, hash(authSession, code));
        authSession.setAuthNote(OTP_EXPIRES_NOTE, Long.toString(now + ttlSeconds));
        authSession.setAuthNote(OTP_ATTEMPTS_NOTE, "0");
        authSession.setAuthNote(OTP_SENT_AT_NOTE, Long.toString(now));

        Map<String, Object> attributes = new HashMap<>();
        attributes.put("code", code);
        attributes.put("ttlMinutes", Math.max(1, (ttlSeconds + 59) / 60));

        try {
            context.getSession()
                .getProvider(EmailTemplateProvider.class)
                .setRealm(context.getRealm())
                .setUser(user)
                .setAuthenticationSession(authSession)
                .send("ourosEmailOtpSubject", "ouros-email-otp.ftl", attributes);
            return true;
        } catch (EmailException exception) {
            clearChallenge(authSession);
            context.failureChallenge(
                AuthenticationFlowError.INTERNAL_ERROR,
                context.form().setError("ourosEmailOtpDeliveryError").createForm("ouros-email-otp-login.ftl")
            );
            return false;
        }
    }

    private static Response renderForm(AuthenticationFlowContext context, String messageKey) {
        var form = context.form()
            .setAttribute("maskedEmail", maskEmail(context.getUser() == null ? null : context.getUser().getEmail()));
        if (messageKey != null) {
            form.setError(messageKey);
        }
        return form.createForm("ouros-email-otp-login.ftl");
    }

    static boolean hasUsableEmail(UserModel user) {
        return user != null && user.getEmail() != null && !user.getEmail().isBlank();
    }

    static String generateCode() {
        return String.format(Locale.ROOT, "%06d", RANDOM.nextInt(1_000_000));
    }

    static boolean hasLiveChallenge(AuthenticationSessionModel authSession, long now) {
        String hash = authSession.getAuthNote(OTP_HASH_NOTE);
        long expiresAt = parseLong(authSession.getAuthNote(OTP_EXPIRES_NOTE), 0L);
        return hash != null && !hash.isBlank() && expiresAt > now;
    }

    static boolean matches(AuthenticationSessionModel authSession, String code) {
        String expected = authSession.getAuthNote(OTP_HASH_NOTE);
        if (expected == null) {
            return false;
        }
        byte[] expectedBytes = expected.getBytes(StandardCharsets.UTF_8);
        byte[] actualBytes = hash(authSession, code).getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(expectedBytes, actualBytes);
    }

    static String hash(AuthenticationSessionModel authSession, String code) {
        String sessionId = authSession.getParentSession().getId();
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] bytes = digest.digest((sessionId + ":" + code).getBytes(StandardCharsets.UTF_8));
            return toHex(bytes);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
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

    private static String toHex(byte[] bytes) {
        StringBuilder builder = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            builder.append(Character.forDigit((value >>> 4) & 0xF, 16));
            builder.append(Character.forDigit(value & 0xF, 16));
        }
        return builder.toString();
    }

    private static void clearChallenge(AuthenticationSessionModel authSession) {
        authSession.removeAuthNote(OTP_HASH_NOTE);
        authSession.removeAuthNote(OTP_EXPIRES_NOTE);
        authSession.removeAuthNote(OTP_ATTEMPTS_NOTE);
        authSession.removeAuthNote(OTP_SENT_AT_NOTE);
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
