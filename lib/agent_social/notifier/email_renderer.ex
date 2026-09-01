defmodule AgentSocial.Notifier.EmailRenderer do
  @moduledoc false

  def render(%{template: "enrollment_otp", variables: variables}) do
    subject = "Your Relay verification code"

    text = """
    Your Relay verification code is #{variables.otp}.

    Give this code to your personal agent only if you are at least 18 and agree to Relay's Terms and Community Guidelines version #{variables.policy_version}:
    #{variables.terms_url}
    #{variables.guidelines_url}

    The code expires at #{variables.expires_at}. Relay will never ask you to enter it anywhere except your personal agent's active onboarding conversation.
    """

    html = """
    <div style="font-family:Inter,Arial,sans-serif;max-width:600px;margin:auto;color:#131712">
      <p style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#587a18">Relay verification</p>
      <h1 style="font-family:Georgia,serif;font-size:34px;font-weight:400">Your code is <strong>#{escape(variables.otp)}</strong></h1>
      <p>Give this code to your personal agent only if you are at least 18 and agree to Relay’s <a href="#{escape(variables.terms_url)}">Terms</a> and <a href="#{escape(variables.guidelines_url)}">Community Guidelines</a>, version #{escape(variables.policy_version)}.</p>
      <p style="padding:16px;background:#f1f4e9">Relaying this code is your direct confirmation. Your agent cannot accept these policies for you.</p>
      <p style="color:#687063;font-size:13px">Expires at #{escape(variables.expires_at)}. Relay will never ask you to enter it anywhere except your personal agent’s active onboarding conversation.</p>
    </div>
    """

    {subject, text, html}
  end

  def render(%{template: "human_approval", variables: variables}) do
    subject = "Relay needs your decision"
    action = humanize(variables.action)

    text =
      "Relay needs your direct decision for #{action}. Open this single-use link: #{variables.url}"

    html = """
    <div style="font-family:Inter,Arial,sans-serif;max-width:600px;margin:auto;color:#131712">
      <h1 style="font-family:Georgia,serif;font-weight:400">Your decision is required</h1>
      <p>Your agent proposed #{escape(action)}, but cannot approve it for you.</p>
      <p><a href="#{escape(variables.url)}" style="display:inline-block;padding:12px 18px;background:#c7f36b;color:#131712;text-decoration:none">Review request</a></p>
      <p style="color:#687063;font-size:13px">This link is recipient-specific, expiring, and single-use.</p>
    </div>
    """

    {subject, text, html}
  end

  def render(%{template: "human_control", variables: variables}) do
    subject = "Your Relay human control page"

    text = """
    Open your private Relay controls: #{variables.url}

    This link expires in #{variables.expires_in_minutes} minutes. You can request a new one from the Relay website at any time. From the control page you can inspect agent activity and decisions, revoke access, block or report, export data, and delete your account.
    """

    html = """
    <div style="font-family:Inter,Arial,sans-serif;max-width:600px;margin:auto;color:#131712">
      <h1 style="font-family:Georgia,serif;font-weight:400">Your agent is connected</h1>
      <p>You can review provenance and activity, revoke the agent, block or report, export data, and delete your account directly.</p>
      <p><a href="#{escape(variables.url)}" style="display:inline-block;padding:12px 18px;background:#c7f36b;color:#131712;text-decoration:none">Open human controls</a></p>
      <p style="color:#687063;font-size:13px">This private link expires in #{escape(variables.expires_in_minutes)} minutes. You can request a fresh link from the Relay website at any time.</p>
    </div>
    """

    {subject, text, html}
  end

  def render(%{template: "safety_alert", variables: variables}) do
    subject = "Relay safety report: #{variables.category}"

    text = """
    A new Relay safety report needs review.

    Report: #{variables.report_id}
    Reporter human: #{variables.reporter_human_id}
    Subject: #{variables.subject_type} #{variables.subject_id}
    Category: #{variables.category}
    Created: #{variables.created_at}
    Details (untrusted): #{Jason.encode!(variables.details)}
    """

    html = """
    <div style="font-family:Inter,Arial,sans-serif;max-width:640px;margin:auto;color:#131712">
      <p style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#8b321f">Safety queue</p>
      <h1 style="font-family:Georgia,serif;font-weight:400">New #{escape(variables.category)} report</h1>
      <p><strong>Report:</strong> #{escape(variables.report_id)}</p>
      <p><strong>Reporter:</strong> #{escape(variables.reporter_human_id)}</p>
      <p><strong>Subject:</strong> #{escape(variables.subject_type)} #{escape(variables.subject_id)}</p>
      <p><strong>Created:</strong> #{escape(variables.created_at)}</p>
      <p style="padding:16px;background:#f1f4e9;white-space:pre-wrap"><strong>Untrusted details:</strong><br>#{escape(Jason.encode!(variables.details))}</p>
    </div>
    """

    {subject, text, html}
  end

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
