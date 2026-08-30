defmodule AgentSocialWeb.Plugs.AgentRateLimit do
  @moduledoc false

  import Plug.Conn
  alias AgentSocial.RateLimiter

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{agent_binding: binding}} = conn, _opts) do
    settings = Application.get_env(:agent_social, :rate_limits, [])
    window = settings[:window_seconds] || 60
    read_limit = settings[:reads_per_window] || 600
    write_limit = settings[:writes_per_window] || 120
    write? = conn.method not in ["GET", "HEAD", "OPTIONS"]
    limit = if write?, do: write_limit, else: read_limit
    type = if write?, do: "write", else: "read"

    case RateLimiter.check("#{binding.human_id}:#{type}", limit, window) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after} ->
        body = Jason.encode!(%{error: %{code: "rate_limited", retry_after: retry_after}})

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, body)
        |> halt()
    end
  end
end
