package app.ouros.keycloak.otp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
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
import java.nio.charset.StandardCharsets;
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
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

class OurosEmailOtpAuthenticatorTest {
    private static final byte[] TEST_SECRET =
        "test-email-otp-hmac-secret-0123456789abcdef".getBytes(StandardCharsets.UTF_8);

    private final OurosEmailOtpAuthenticator authenticator =
        new OurosEmailOtpAuthenticator(() -> TEST_SECRET);

    @Test
    void authenticateSendsChallengeWithoutPersistingOtpDigestInAuthSession() throws Exception {
        Fixture fixture = new Fixture();

        authenticator.authenticate(fixture.context);

        verify(fixture.email).send(
            eq("ourosEmailOtpSubject"),
            eq("ouros-email-otp.ftl"),
            anyMap()
        );
        verify(fixture.context).challenge(fixture.response);

        String challengeId = fixture.notes.get(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE);
        assertNotNull(challengeId);
        assertFalse(fixture.notes.containsKey("ouros.email-otp.hash"));

        Map<String, String> storedState =
            fixture.singleUseState.get(fixture.challengeStoreKey(challengeId));
        assertNotNull(storedState);
        String storedDigest = storedState.get(OurosEmailOtpAuthenticator.CHALLENGE_DIGEST);
        assertNotNull(storedDigest);
        assertEquals(64, storedDigest.length());
        assertFalse(storedDigest.matches("\\d{6}"));
        assertEquals("0", storedState.get(OurosEmailOtpAuthenticator.CHALLENGE_ATTEMPTS));
    }

    @Test
    void authenticateReusesLiveChallengeWithoutSendingAgain() throws Exception {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");

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
    void actionAcceptsMatchingCodeAndConsumesChallenge() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.form.putSingle("otp", "123456");

        authenticator.action(fixture.context);

        verify(fixture.context).success();
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE));
        assertTrue(
            fixture.singleUseState.values().stream()
                .anyMatch(state -> OurosEmailOtpAuthenticator.TERMINAL_CONSUMED.equals(
                    state.get(OurosEmailOtpAuthenticator.TERMINAL_STATUS)
                ))
        );
    }

    @Test
    void atomicConsumeAllowsOnlyOneSuccessForSameChallenge() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        String challengeId =
            fixture.notes.get(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE);
        long expiresAt =
            Long.parseLong(fixture.notes.get(OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE));

        AuthenticationSessionModel competingSession = mock(AuthenticationSessionModel.class);
        when(competingSession.getParentSession()).thenReturn(fixture.rootSession);
        when(competingSession.getTabId()).thenReturn("tab-id");
        when(competingSession.getAuthNote(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE))
            .thenReturn(challengeId);
        when(competingSession.getAuthNote(OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE))
            .thenReturn(Long.toString(expiresAt));

        OurosEmailOtpAuthenticator.ConsumeResult first =
            OurosEmailOtpAuthenticator.consumeChallenge(
                fixture.keycloakSession,
                fixture.authSession,
                "123456",
                Instant.now().getEpochSecond(),
                5,
                TEST_SECRET
            );
        OurosEmailOtpAuthenticator.ConsumeResult second =
            OurosEmailOtpAuthenticator.consumeChallenge(
                fixture.keycloakSession,
                competingSession,
                "123456",
                Instant.now().getEpochSecond(),
                5,
                TEST_SECRET
            );

        assertEquals(OurosEmailOtpAuthenticator.ConsumeResult.SUCCESS, first);
        assertEquals(OurosEmailOtpAuthenticator.ConsumeResult.ALREADY_CONSUMED, second);
    }

    @Test
    void actionRejectsMalformedCodeWithoutConsumingAttempt() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.form.putSingle("otp", "12x");

        authenticator.action(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpInvalid");
        verify(fixture.context).challenge(fixture.response);
        assertEquals(
            "0",
            fixture.challengeState().get(OurosEmailOtpAuthenticator.CHALLENGE_ATTEMPTS)
        );
    }

    @Test
    void actionFailsClosedAfterMaximumInvalidAttempts() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.challengeState().put(OurosEmailOtpAuthenticator.CHALLENGE_ATTEMPTS, "4");
        fixture.form.putSingle("otp", "654321");

        authenticator.action(fixture.context);

        verify(fixture.forms).setError("ourosEmailOtpTooManyAttempts");
        verify(fixture.context).failureChallenge(
            AuthenticationFlowError.INVALID_CREDENTIALS,
            fixture.response
        );
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE));
    }

    @Test
    void invalidAttemptIsReinsertedWithIncrementedCounter() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");

        OurosEmailOtpAuthenticator.ConsumeResult result =
            OurosEmailOtpAuthenticator.consumeChallenge(
                fixture.keycloakSession,
                fixture.authSession,
                "654321",
                Instant.now().getEpochSecond(),
                5,
                TEST_SECRET
            );

        assertEquals(OurosEmailOtpAuthenticator.ConsumeResult.INVALID, result);
        assertEquals(
            "1",
            fixture.challengeState().get(OurosEmailOtpAuthenticator.CHALLENGE_ATTEMPTS)
        );
    }

    @Test
    void missingChallengeDuringLiveWindowIsReportedAsBusy() {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.singleUseState.clear();

        OurosEmailOtpAuthenticator.ConsumeResult result =
            OurosEmailOtpAuthenticator.consumeChallenge(
                fixture.keycloakSession,
                fixture.authSession,
                "123456",
                Instant.now().getEpochSecond(),
                5,
                TEST_SECRET
            );

        assertEquals(OurosEmailOtpAuthenticator.ConsumeResult.BUSY, result);
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
    }

    @Test
    void actionReissuesExpiredChallenge() throws Exception {
        Fixture fixture = new Fixture();
        fixture.liveChallenge("123456");
        fixture.notes.put(
            OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE,
            Long.toString(Instant.now().getEpochSecond() - 1)
        );
        fixture.singleUseState.clear();
        fixture.form.putSingle("otp", "123456");

        authenticator.action(fixture.context);

        verify(fixture.email).send(
            eq("ourosEmailOtpSubject"),
            eq("ouros-email-otp.ftl"),
            anyMap()
        );
        verify(fixture.forms).setError("ourosEmailOtpExpired");
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
        assertFalse(fixture.notes.containsKey(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE));
        assertTrue(fixture.singleUseState.isEmpty());
        verify(fixture.context, never()).challenge(fixture.response);
    }

    @Test
    void hmacDigestIsBoundToChallengeAndRequiresStrongSecret() {
        Fixture fixture = new Fixture();

        String first = OurosEmailOtpAuthenticator.hmacDigest(
            fixture.authSession,
            "challenge-a",
            "123456",
            TEST_SECRET
        );
        String second = OurosEmailOtpAuthenticator.hmacDigest(
            fixture.authSession,
            "challenge-b",
            "123456",
            TEST_SECRET
        );

        assertEquals(64, first.length());
        assertNotEquals(first, second);
        assertTrue(OurosEmailOtpAuthenticator.constantTimeEquals(first, first));
        assertFalse(OurosEmailOtpAuthenticator.constantTimeEquals(first, second));
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
        assertTrue(
            authenticator.configuredFor(
                mock(KeycloakSession.class),
                mock(RealmModel.class),
                userWithEmail()
            )
        );
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
        final SingleUseObjectProvider singleUse = mock(SingleUseObjectProvider.class);
        final EmailTemplateProvider email = mock(EmailTemplateProvider.class);
        final LoginFormsProvider forms = mock(LoginFormsProvider.class);
        final HttpRequest httpRequest = mock(HttpRequest.class);
        final Response response = mock(Response.class);
        final MultivaluedHashMap<String, String> form = new MultivaluedHashMap<>();
        final Map<String, String> notes = new HashMap<>();
        final Map<String, Map<String, String>> singleUseState = new HashMap<>();

        Fixture() {
            when(context.getUser()).thenReturn(user);
            when(user.getEmail()).thenReturn("user@example.com");
            when(context.getAuthenticationSession()).thenReturn(authSession);
            when(authSession.getParentSession()).thenReturn(rootSession);
            when(authSession.getTabId()).thenReturn("tab-id");
            when(rootSession.getId()).thenReturn("root-session");
            when(context.getSession()).thenReturn(keycloakSession);
            when(context.getRealm()).thenReturn(realm);
            when(keycloakSession.singleUseObjects()).thenReturn(singleUse);
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

            when(singleUse.get(anyString()))
                .thenAnswer(invocation -> {
                    Map<String, String> state = singleUseState.get(invocation.getArgument(0));
                    return state == null ? null : new HashMap<>(state);
                });
            when(singleUse.remove(anyString()))
                .thenAnswer(invocation -> singleUseState.remove(invocation.getArgument(0)));
            doAnswer(invocation -> {
                singleUseState.put(
                    invocation.getArgument(0),
                    new HashMap<>((Map<String, String>) invocation.getArgument(2))
                );
                return null;
            }).when(singleUse).put(anyString(), anyLong(), anyMap());
        }

        void liveChallenge(String code) {
            String challengeId = "test-challenge";
            long expiresAt = Instant.now().getEpochSecond() + 120;
            notes.put(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE, challengeId);
            notes.put(
                OurosEmailOtpAuthenticator.OTP_EXPIRES_NOTE,
                Long.toString(expiresAt)
            );
            notes.put(
                OurosEmailOtpAuthenticator.OTP_SENT_AT_NOTE,
                Long.toString(Instant.now().getEpochSecond() - 60)
            );

            Map<String, String> state = new HashMap<>();
            state.put(
                OurosEmailOtpAuthenticator.CHALLENGE_DIGEST,
                OurosEmailOtpAuthenticator.hmacDigest(
                    authSession,
                    challengeId,
                    code,
                    TEST_SECRET
                )
            );
            state.put(OurosEmailOtpAuthenticator.CHALLENGE_ATTEMPTS, "0");
            singleUseState.put(challengeStoreKey(challengeId), state);
        }

        Map<String, String> challengeState() {
            String challengeId = notes.get(OurosEmailOtpAuthenticator.OTP_CHALLENGE_ID_NOTE);
            return singleUseState.get(challengeStoreKey(challengeId));
        }

        String challengeStoreKey(String challengeId) {
            return "ouros-email-otp:" + challengeId;
        }
    }
}
