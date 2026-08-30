defmodule AgentSocialWeb.Plugs.AgentIdempotency do
  @moduledoc false
  import Plug.Conn

  @read_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in @read_methods, do: conn

  def call(conn, _opts) do
    with [key] when byte_size(key) in 8..128 <- get_req_header(conn, "idempotency-key"),
         binding when not is_nil(binding) <- conn.assigns[:agent_binding],
         operation <- conn.method <> " " <> conn.request_path,
         {:ok, record} <-
           AgentSocial.Idempotency.claim(binding.human_id, operation, key, conn.body_params) do
      conn
      |> assign(:idempotency_key, key)
      |> register_before_send(fn conn ->
        case Jason.decode(conn.resp_body || "") do
          {:ok, body} when is_map(body) ->
            :ok = AgentSocial.Idempotency.complete(record.id, conn.status, body)
            conn

          _ ->
            conn
        end
      end)
    else
      {:replay, status, body} -> replay(conn, status, body)
      {:error, :idempotency_payload_mismatch} -> conflict(conn, "idempotency_payload_mismatch")
      {:error, :idempotency_in_progress} -> conflict(conn, "idempotency_in_progress")
      _ -> bad_request(conn, "idempotency_key_required")
    end
  end

  defp replay(conn, status, body) do
    conn
    |> put_resp_header("idempotent-replayed", "true")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp conflict(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(409, Jason.encode!(%{error: %{code: code, message: "Idempotency conflict"}}))
    |> halt()
  end

  defp bad_request(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      400,
      Jason.encode!(%{error: %{code: code, message: "A valid idempotency key is required"}})
    )
    |> halt()
  end
end
