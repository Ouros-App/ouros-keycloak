package app.ouros.keycloak.otp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.Response;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

class OurosEmailOtpAuthenticatorTest {
    private final OurosEmailOtpAuthenticator authenticator = new OurosEmailOtpAuthenticator();

    @Test
    void authenticateSendsChallengeAndStoresOnlyDigest() throws Exception {
        Fixture fixture = new Fixture();

        authenticator.authenticate(fixture.context);

        verify(fixture.email).send(
            eq("ourosEmailOtpSubject"),
            eq("ouros-email-otp.ftl"),
            anyMap()
        );
        verify(fixture.context).challenge(fixture.response);

        String storedHash = fixture.notes.get(OurosEmailOtpAuthenticator.OTP_HASH_NOTE);
        assertNotNull(storedHash);
        assertEquals(64, storedHash.length());
        assertFalse(storedHash.matches("\\d{6}"));
        assertEquals("0", fixture.notes.get(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE));
        assertTrue(
            Long.parseLong(fixture.notes.get(OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE))
                > Instant.now().getEpochSecond()
        );
    }

    @Test
    void authenticateReusesLiveChallengeWithoutSendingAgain() throws Exception {
        Fixture fixture = new Fixture();
        fixture.notes.put(OurosEmailOtpAuthenticator.OTP_HASH_NOTE, "existing-hash");
        fixture.notes.put(
            OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE,
            Long.toString(Instant.now().getEpochSecond() + 120)
        );

        authenticator.authenticate(fixture.context);

        verify(fixture.email, never()).send(anyString(), anyString(), anyMap());
        verify(fixture.context).challenge(fixture.response);
    }

    @Test
    void authenticateRejectsUserWithoutEmail() {
        Fixture fixture = new Fixture();
        when(fixture.user.getEmail()).thenReturn(null);

        authenticator.authenticate(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpMissingEmail");
        verify(fixture.context).failureChallenge(
            AuthenticationFlowError.INVALID_USER,
            fixture.response
        );
    }

    @Test
    void actionAcceptsMatchingCodeAndClearsChallenge() {
        Fixture fixture = new Fixture();
        String code = "123456";
        fixture.liveChallenge(code);
        fixture.form.putSingle("otp", code);

        authenticator.action(fixture.context);

        verify(fixture.context).success();
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_HASH_NOTE));
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE));
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE));
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_SENT_AT_NOTE));
    }

    @Test
    void actionRejectsMalformedCodeWithoutConsumingAttempt() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.form.putSingle("otp", "12x");

        authenticator.action(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpInvalid");
        verify(fixture.context).challenge(fixture.response);
        assertEquals("0", fixture.notes.get(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE));
    }

    @Test
    void actionFailsClosedAfterMaximumInvalidAttempts() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.notes.put(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE, "4");
        fixture.form.putSingle("otp", "654321");

        authenticator.action(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpTooManyAttempts");
        verify(fixture.context).failureChallenge(
            AuthenticationFlowError.INVALID_CREDENTIALS,
            fixture.response
        );
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_HASH_NOTE));
    }

    @Test
    void actionRateLimitsImmediateResend() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.notes.put(
            OurosEmailOtpAuthenticator.OTP_SENT_AT_NOTE,
            Long.toString(Instant.now().getEpochSecond())
        );
        fixture.form.putSingle("resend", "true");

        authenticator.action(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpResendTooSoon");
        verify(fixture.context).challenge(fixture.response);
    }


    @Test
    void actionResendsAfterCooldown() throws Exception {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.notes.put(
            OurosEmailOtpAuthenticator.OTP_SENT_AT_NOTE,
            Long.toString(Instant.now().getEpochSecond() - 120)
        );
        fixture.form.putSingle("resend", "true");

        authenticator.action(fixture.context);

        verify(fixture.email).send(
            eq("ourosEmailOtpSubject"),
            eq("ouros-email-otp.ftl"),
            anyMap()
        );
        verify(fixture.forms).setError("ourosEmailOtpResent");
        verify(fixture.context).challenge(fixture.response);
        assertEquals("0", fixture.notes.get(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE));
    }

    @Test
    void actionReissuesExpiredChallenge() throws Exception {
        Fixture fixture = new Fixture();
        fixture.notes.put(OurosEmailOtpAuthenticator.OTP_HASH_NOTE, "expired-hash");
        fixture.notes.put(
            OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE,
            Long.toString(Instant.now().getEpochSecond() - 1)
        );

        authenticator.action(fixture.context);

        verify(fixture.email).send(
            eq("ourosEmailOtpSubject"),
            eq("ouros-email-otp.ftl"),
            anyMap()
        );
        verify(fixture.forms).setError("ourosEmailOtpExpired");
        verify(fixture.context).challenge(fixture.response);
        assertNotEquals("expired-hash", fixture.notes.get(OurosEmailOtpAuthenticator.OTP_HASH_NOTE));
    }

    @Test
    void actionCountsInvalidCodeBeforeAttemptLimit() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.form.putSingle("otp", "654321");

        authenticator.action(fixture.context);

        assertEquals("1", fixture.notes.get(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE));
        verify(fixture.forms).setError("ourosEmailOtpInvalid");
        verify(fixture.context).challenge(fixture.response);
    }

    @Test
    void authenticateFailsClosedWhenEmailDeliveryFails() throws Exception {
        Fixture fixture = new Fixture();
        doThrow(new EmailException("smtp unavailable"))
            .when(fixture.email)
            .send(anyString(), anyString(), anyMap());

        authenticator.authenticate(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpDeliveryError");
        verify(fixture.context).failureChallenge(
            AuthenticationFlowError.INTERNAL_ERROR,
            fixture.response
        );
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_HASH_NOTE));
        verify(fixture.context, never()).challenge(fixture.response);
    }

    @Test
    void helperMethodsHandleExpectedEdgeCases() {
        assertEquals("***", OurosEmailOtpAuthenticator.maskEmail(null));
        assertEquals("***", OurosEmailOtpAuthenticator.maskEmail("invalid"));
        assertEquals("****@example.com", OurosEmailOtpAuthenticator.maskEmail("@example.com"));
        assertEquals("u***@example.com", OurosEmailOtpAuthenticator.maskEmail("user@example.com"));

        assertEquals(7L, OurosEmailOtpAuthenticator.parseLong(null, 7L));
        assertEquals(7L, OurosEmailOtpAuthenticator.parseLong("   ", 7L));
        assertEquals(7L, OurosEmailOtpAuthenticator.parseLong("not-a-number", 7L));
        assertEquals(42L, OurosEmailOtpAuthenticator.parseLong("42", 7L));

        String first = OurosEmailOtpAuthenticator.generateCode();
        String second = OurosEmailOtpAuthenticator.generateCode();
        assertTrue(first.matches("\\d{6}"));
        assertTrue(second.matches("\\d{6}"));

        UserModel user = mock(UserModel.class);
        when(user.getEmail()).thenReturn("user@example.com");
        assertTrue(OurosEmailOtpAuthenticator.hasUsableEmail(user));
        when(user.getEmail()).thenReturn(" ");
        assertFalse(OurosEmailOtpAuthenticator.hasUsableEmail(user));
        assertFalse(OurosEmailOtpAuthenticator.hasUsableEmail(null));

        assertTrue(authenticator.requiresUser());
        assertTrue(authenticator.configuredFor(mock(KeycloakSession.class), mock(RealmModel.class), userWithEmail()));

        Fixture fixture = new Fixture();
        assertFalse(OurosEmailOtpAuthenticator.matches(fixture.authSession, "000000"));
        fixture.notes.put(OurosEmailOtpAuthenticator.OTP_HASH_NOTE, " ");
        fixture.notes.put(OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE, Long.toString(Instant.now().getEpochSecond() + 60));
        assertFalse(OurosEmailOtpAuthenticator.hasLiveChallenge(fixture.authSession, Instant.now().getEpochSecond()));
        assertNotEquals("", OurosEmailOtpAuthenticator.hash(fixture.authSession, "000000"));
    }

    private static UserModel userWithEmail() {
        UserModel user = mock(UserModel.class);
        when(user.getEmail()).thenReturn("user@example.com");
        return user;
    }

    private static final class Fixture {
        final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
        final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        final RootAuthenticationSessionModel rootSession = mock(RootAuthenticationSessionModel.class);
        final UserModel user = mock(UserModel.class);
        final KeycloakSession keycloakSession = mock(KeycloakSession.class);
        final RealmModel realm = mock(RealmModel.class);
        final EmailTemplateProvider email = mock(EmailTemplateProvider.class);
        final LoginFormsProvider forms = mock(LoginFormsProvider.class);
        final HttpRequest httpRequest = mock(HttpRequest.class);
        final Response response = mock(Response.class);
        final MultivaluedHashMap<String, String> form = new MultivaluedHashMap<>();
        final Map<String, String> notes = new HashMap<>();

        Fixture() {
            when(context.getUser()).thenReturn(user);
            when(user.getEmail()).thenReturn("user@example.com");
            when(context.getAuthenticationSession()).thenReturn(authSession);
            when(authSession.getParentSession()).thenReturn(rootSession);
            when(rootSession.getId()).thenReturn("root-session");
            when(context.getSession()).thenReturn(keycloakSession);
            when(context.getRealm()).thenReturn(realm);
            when(keycloakSession.getProvider(EmailTemplateProvider.class)).thenReturn(email);
            when(email.setRealm(realm)).thenReturn(email);
            when(email.setUser(user)).thenReturn(email);
            when(email.setAuthenticationSession(authSession)).thenReturn(email);

            when(context.form()).thenReturn(forms);
            when(forms.setAttribute(anyString(), any())).thenReturn(forms);
            when(forms.setError(anyString())).thenReturn(forms);
            when(forms.createForm(anyString())).thenReturn(response);

            when(context.getHttpRequest()).thenReturn(httpRequest);
            when(httpRequest.getDecodedFormParameters()).thenReturn(form);

            when(authSession.getAuthNote(anyString()))
                .thenAnswer(invocation -> notes.get(invocation.getArgument(0)));
            doAnswer(invocation -> {
                notes.put(invocation.getArgument(0), invocation.getArgument(1));
                return null;
            }).when(authSession).setAuthNote(anyString(), anyString());
            doAnswer(invocation -> {
                notes.remove(invocation.getArgument(0));
                return null;
            }).when(authSession).removeAuthNote(anyString());
        }

        void liveChallenge(String code) {
            notes.put(
                OurosEmailOtpAuthenticator.OTP_HASH_NOTE,
                OurosEmailOtpAuthenticator.hash(authSession, code)
            );
            notes.put(
                OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE,
                Long.toString(Instant.now().getEpochSecond() + 120)
            );
            notes.put(OurosEmailOtpAuthenticator.OTP_ATTEMPTS_NOTE, "0");
            notes.put(
                OurosEmailOtpAuthenticator.OTP_SENT_AT_NOTE,
                Long.toString(Instant.now().getEpochSecond() - 60)
            );
        }
    }
}
