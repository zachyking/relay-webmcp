defmodule AgentSocial.NotifierTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias AgentSocial.Notifier

  setup do
    previous = Application.fetch_env!(:agent_social, Notifier)

    Application.put_env(:agent_social, Notifier,
      adapter: AgentSocial.Notifier.SMTPAdapter,
      from_address: "relay@example.test",
      from_name: "Relay"
    )

    on_exit(fn -> Application.put_env(:agent_social, Notifier, previous) end)
  end

  test "SMTP adapter renders and delivers the enrollment message" do
    assert :ok =
             Notifier.enrollment_otp("owner@example.test", "482913", %{
               policy_version: "1.0-beta",
               terms_url: "https://relay.example.test/terms",
               guidelines_url: "https://relay.example.test/community-guidelines",
               expires_at: "2026-08-31T12:00:00Z"
             })

    assert_email_sent(fn email ->
      assert email.from == {"Relay", "relay@example.test"}
      assert email.to == [{"", "owner@example.test"}]
      assert email.subject == "Your Relay verification code"
      assert email.text_body =~ "482913"
      assert email.html_body =~ "Relay verification"
    end)
  end
end
