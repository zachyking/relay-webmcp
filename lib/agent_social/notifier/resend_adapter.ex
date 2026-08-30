defmodule AgentSocial.Notifier.ResendAdapter do
  @moduledoc false

  alias AgentSocial.Notifier.EmailRenderer

  def deliver(message) do
    settings = Application.fetch_env!(:agent_social, AgentSocial.Notifier)
    {subject, text, html} = EmailRenderer.render(message)

    case Req.post(settings[:endpoint] || "https://api.resend.com/emails",
           headers: [{"authorization", "Bearer #{settings[:api_key]}"}],
           json: %{
             from: settings[:from],
             to: [message.to],
             subject: subject,
             text: text,
             html: html
           },
           redirect: false,
           receive_timeout: 10_000,
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:notification_status, status}}
      {:error, reason} -> {:error, {:notification_transport, reason}}
    end
  end
end
