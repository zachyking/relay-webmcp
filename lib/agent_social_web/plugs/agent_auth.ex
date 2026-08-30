defmodule AgentSocialWeb.Plugs.AgentAuth do
  @moduledoc false
  import Ecto.Query
  import Plug.Conn
  alias AgentSocial.Identity
  alias AgentSocial.Identity.{AgentBinding, Human}
  alias AgentSocial.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:error, :missing} <- from_session(conn),
         {:error, :missing} <- from_bearer(conn),
         {:error, :missing} <- from_internal_signature(conn) do
      conn |> unauthorized() |> halt()
    else
      {:ok, binding} -> assign(conn, :agent_binding, binding)
      {:error, _reason} -> conn |> unauthorized() |> halt()
    end
  end

  defp from_session(conn) do
    case get_session(conn, :agent_binding_id) do
      nil ->
        {:error, :missing}

      id ->
        case Repo.get(AgentBinding, id) |> Repo.preload(:human) do
          %AgentBinding{active: true, human: %{status: "active"}} = binding -> {:ok, binding}
          _ -> {:error, :invalid_session}
        end
    end
  end

  defp from_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Identity.authenticate_token(token)
      _ -> {:error, :missing}
    end
  end

  defp from_internal_signature(conn) do
    with {:ok, identity_type, identity} <- internal_identity(conn),
         [scopes_header] <- get_req_header(conn, "x-agent-scopes"),
         [client_id] <- get_req_header(conn, "x-agent-client-id"),
         [timestamp] <- get_req_header(conn, "x-agent-timestamp"),
         [nonce] <- get_req_header(conn, "x-agent-nonce"),
         [signature] <- get_req_header(conn, "x-agent-signature"),
         {unix, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - unix) <= 60,
         secret when is_binary(secret) <- System.get_env("MCP_INTERNAL_SECRET"),
         expected <-
           internal_signature(
             secret,
             timestamp,
             nonce,
             identity_type,
             identity,
             scopes_header,
             client_id,
             idempotency_key(conn),
             conn.method,
             conn.request_path
           ),
         true <- Plug.Crypto.secure_compare(expected, signature),
         :ok <- consume_nonce(nonce),
         %AgentBinding{} = binding <- internal_binding(identity_type, identity) do
      delegated_scopes = String.split(scopes_header, " ", trim: true)

      {:ok,
       %{
         binding
         | scopes: Enum.filter(binding.scopes, &(&1 in delegated_scopes)),
           client_id: client_id
       }}
    else
      [] -> {:error, :missing}
      _ -> {:error, :invalid_internal_signature}
    end
  end

  defp internal_identity(conn) do
    case {get_req_header(conn, "x-agent-human-id"), get_req_header(conn, "x-agent-oidc-sub")} do
      {[human_id], []} -> {:ok, "human_id", human_id}
      {[], [subject]} -> {:ok, "oidc_sub", subject}
      {[], []} -> {:error, :missing}
      _ -> {:error, :ambiguous_identity}
    end
  end

  defp internal_binding("human_id", human_id) do
    Repo.get_by(AgentBinding, human_id: human_id, active: true) |> Repo.preload(:human)
  end

  defp internal_binding("oidc_sub", subject) do
    from(binding in AgentBinding,
      join: human in Human,
      on: human.id == binding.human_id,
      where: human.oidc_subject == ^subject and binding.active == true,
      preload: [human: human]
    )
    |> Repo.one()
  end

  defp internal_signature(
         secret,
         timestamp,
         nonce,
         identity_type,
         identity,
         scopes,
         client_id,
         idempotency_key,
         method,
         path
       ) do
    payload =
      Enum.join(
        [
          timestamp,
          nonce,
          identity_type,
          identity,
          scopes,
          client_id,
          idempotency_key,
          method,
          path
        ],
        ":"
      )

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] -> key
      _ -> ""
    end
  end

  defp consume_nonce(nonce) when is_binary(nonce) and byte_size(nonce) in 16..128 do
    case AgentSocial.RateLimiter.check("internal-nonce:#{nonce}", 1, 120) do
      :ok -> :ok
      _ -> {:error, :replayed_internal_request}
    end
  end

  defp consume_nonce(_), do: {:error, :invalid_internal_nonce}

  defp unauthorized(conn) do
    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer resource_metadata="#{AgentSocialWeb.Endpoint.url()}/.well-known/oauth-protected-resource")
    )
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{
      error: %{code: "unauthorized", message: "Valid agent authentication is required"}
    })
  end
end
