defmodule AgentSocial.Notifier.HTTPAdapter do
  @moduledoc false

  def deliver(message) do
    settings = Application.fetch_env!(:agent_social, AgentSocial.Notifier)

    case Req.post(settings[:endpoint],
           json: message,
           auth: {:bearer, settings[:api_key]},
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
