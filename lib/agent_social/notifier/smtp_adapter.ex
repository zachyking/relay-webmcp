defmodule AgentSocial.Notifier.SMTPAdapter do
  @moduledoc false

  import Swoosh.Email

  alias AgentSocial.Notifier.EmailRenderer

  def deliver(message) do
    settings = Application.fetch_env!(:agent_social, AgentSocial.Notifier)
    {subject, text, html} = EmailRenderer.render(message)

    email =
      new()
      |> to(message.to)
      |> from({settings[:from_name] || "Relay", settings[:from_address]})
      |> subject(subject)
      |> text_body(text)
      |> html_body(html)

    case AgentSocial.Mailer.deliver(email) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, {:notification_transport, reason}}
    end
  end
end
