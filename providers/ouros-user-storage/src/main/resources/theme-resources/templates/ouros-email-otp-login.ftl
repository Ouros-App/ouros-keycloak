<#import "template.ftl" as layout>
<@layout.registrationLayout displayInfo=false; section>
  <#if section == "header">
    ${msg("ourosEmailOtpTitle")}
  <#elseif section == "form">
    <form id="kc-ouros-email-otp-form" action="${url.loginAction}" method="post">
      <p>${msg("ourosEmailOtpPrompt", maskedEmail!"***")}</p>
      <div>
        <label for="otp">${msg("ourosEmailOtpCode")}</label>
        <input
          id="otp"
          name="otp"
          type="text"
          inputmode="numeric"
          autocomplete="one-time-code"
          pattern="[0-9]{6}"
          minlength="6"
          maxlength="6"
          autofocus
        />
      </div>
      <div>
        <button type="submit">${msg("doSubmit")}</button>
        <button type="submit" name="resend" value="true">${msg("ourosEmailOtpResend")}</button>
      </div>
    </form>
  </#if>
</@layout.registrationLayout>
