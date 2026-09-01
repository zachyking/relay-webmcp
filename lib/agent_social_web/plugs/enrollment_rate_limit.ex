defmodule AgentSocialWeb.Plugs.EnrollmentRateLimit do
  @moduledoc false

  import Plug.Conn
  alias AgentSocial.RateLimiter

  def init(opts), do: opts

  def call(conn, _opts) do
    settings = Application.get_env(:agent_social, :enrollment_rate_limits, [])
    window = settings[:window_seconds] || 3_600
    {action, limit} = action_and_limit(conn, settings)
    ip_key = client_ip(conn)

    keys =
      ["enrollment:#{action}:ip:#{ip_key}"] ++
        subject_keys(action, conn.body_params)

    case Enum.find_value(keys, fn key -> limited?(key, limit, window) end) do
      nil -> conn
      retry_after -> reject(conn, retry_after)
    end
  end

  defp action_and_limit(%{request_path: "/api/v1/enrollment/challenges"}, settings),
    do: {:begin, settings[:challenges_per_window] || 5}

  defp action_and_limit(%{request_path: "/api/v1/enrollment/complete"}, settings),
    do: {:complete, settings[:completions_per_window] || 20}

  defp action_and_limit(%{request_path: "/api/v1/browser-session"}, settings),
    do: {:session, settings[:sessions_per_window] || 30}

  defp action_and_limit(_conn, settings), do: {:other, settings[:other_per_window] || 30}

  defp subject_keys(:begin, %{"email" => email}) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    ["enrollment:begin:email:#{digest(normalized)}"]
  end

  defp subject_keys(:complete, %{"challenge_id" => challenge_id}) when is_binary(challenge_id),
    do: ["enrollment:complete:challenge:#{digest(challenge_id)}"]

  defp subject_keys(_, _), do: []

  defp limited?(key, limit, window) do
    case RateLimiter.check(key, limit, window) do
      :ok -> nil
      {:error, :rate_limited, retry_after} -> retry_after
    end
  end

  defp client_ip(conn) do
    ["cf-connecting-ip", "fly-client-ip", "x-real-ip", "x-forwarded-for"]
    |> Enum.find_value(fn header ->
      case get_req_header(conn, header) do
        [value | _] -> value |> String.split(",") |> hd() |> String.trim() |> safe_ip()
        _ -> nil
      end
    end)
    |> Kernel.||(conn.remote_ip |> :inet.ntoa() |> to_string())
  end

  defp safe_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _address} -> value
      {:error, _reason} -> nil
    end
  end

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)

  defp reject(conn, retry_after) do
    body = Jason.encode!(%{error: %{code: "rate_limited", retry_after: retry_after}})

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end
end
