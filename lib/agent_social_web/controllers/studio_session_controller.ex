defmodule AgentSocialWeb.StudioSessionController do
  use AgentSocialWeb, :controller

  alias AgentSocial.Studio

  def create(conn, params) do
    binding = conn.assigns.agent_binding

    with :ok <- require_scope(binding, "content:write"),
         {:ok, key} <- idempotency_key(conn),
         {:ok, session, token} <- Studio.create(binding, params, key) do
      data =
        session
        |> Studio.serialize()
        |> Map.put(:review_url, review_url(conn, token))

      conn |> put_status(:created) |> json(%{data: data})
    else
      error -> respond_error(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    binding = conn.assigns.agent_binding

    with :ok <- require_scope(binding, "content:write"),
         {:ok, session} <- Studio.get_for_agent(binding, id) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  def revise(conn, %{"id" => id, "based_on_version" => version} = params) do
    binding = conn.assigns.agent_binding

    with :ok <- require_scope(binding, "content:write"),
         {:ok, key} <- idempotency_key(conn),
         {:ok, session} <-
           Studio.revise(binding, id, version, Map.delete(params, "id"), key) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  def revise(conn, _params), do: respond_error(conn, {:error, :draft_version_required})

  def publish(conn, %{"id" => id}) do
    binding = conn.assigns.agent_binding

    with :ok <- require_scope(binding, "content:write"),
         {:ok, key} <- idempotency_key(conn),
         {:ok, session} <- Studio.publish_by_agent(binding, id, key) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  defp idempotency_key(conn) do
    case conn.assigns[:idempotency_key] do
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, :idempotency_key_required}
    end
  end

  defp require_scope(binding, scope) do
    if scope in binding.scopes, do: :ok, else: {:error, :insufficient_scope}
  end

  defp respond_error(conn, {:error, reason}), do: respond_error(conn, reason)

  defp respond_error(conn, reason) do
    {status, code} =
      case reason do
        :not_found -> {:not_found, "not_found"}
        :expired -> {:gone, "review_link_expired"}
        :stale_draft_version -> {:conflict, "stale_draft_version"}
        :review_not_ready -> {:conflict, "review_not_ready"}
        :already_published -> {:conflict, "already_published"}
        :insufficient_scope -> {:forbidden, "insufficient_scope"}
        :idempotency_key_required -> {:bad_request, "idempotency_key_required"}
        :draft_version_required -> {:bad_request, "draft_version_required"}
        _ -> {:unprocessable_entity, "invalid_request"}
      end

    conn |> put_status(status) |> json(%{error: %{code: code}})
  end

  defp review_url(conn, token) do
    origin(conn) <> "/studio/review#" <> token
  end

  defp origin(conn) do
    %URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end
end
