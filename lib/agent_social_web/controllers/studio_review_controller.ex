defmodule AgentSocialWeb.StudioReviewController do
  use AgentSocialWeb, :controller

  alias AgentSocial.Studio

  def show(conn, _params) do
    with {:ok, token} <- review_token(conn),
         {:ok, session} <- Studio.get_by_token(token) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  def update(conn, %{"draft_version" => version} = params) do
    with {:ok, token} <- review_token(conn),
         {:ok, session} <- Studio.update_review(token, version, params) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  def update(conn, _params), do: respond_error(conn, {:error, :draft_version_required})

  def ready(conn, %{"draft_version" => version}) do
    with {:ok, token} <- review_token(conn),
         {:ok, session} <- Studio.mark_review_ready(token, version) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  def ready(conn, _params), do: respond_error(conn, {:error, :draft_version_required})

  def publish(conn, _params) do
    with {:ok, token} <- review_token(conn),
         {:ok, key} <- idempotency_key(conn),
         {:ok, session} <- Studio.publish_by_token(token, key) do
      json(conn, %{data: Studio.serialize(session)})
    else
      error -> respond_error(conn, error)
    end
  end

  defp review_token(conn) do
    case get_req_header(conn, "x-relay-review-token") do
      ["rvw_" <> _ = token] -> {:ok, token}
      _ -> {:error, :review_token_required}
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 8..128 -> {:ok, key}
      _ -> {:error, :idempotency_key_required}
    end
  end

  defp respond_error(conn, {:error, reason}), do: respond_error(conn, reason)

  defp respond_error(conn, reason) do
    {status, code} =
      case reason do
        :not_found -> {:not_found, "review_not_found"}
        :expired -> {:gone, "review_link_expired"}
        :stale_draft_version -> {:conflict, "stale_draft_version"}
        :already_published -> {:conflict, "already_published"}
        :agent_disconnected -> {:forbidden, "agent_disconnected"}
        :review_feedback_required -> {:unprocessable_entity, "review_feedback_required"}
        :draft_version_required -> {:bad_request, "draft_version_required"}
        :idempotency_key_required -> {:bad_request, "idempotency_key_required"}
        :review_token_required -> {:unauthorized, "review_token_required"}
        _ -> {:unprocessable_entity, "invalid_request"}
      end

    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
