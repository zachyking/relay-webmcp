defmodule AgentSocialWeb.ApprovalController do
  use AgentSocialWeb, :controller

  alias AgentSocial.Connections

  def show(conn, %{"token" => token}) do
    case Connections.get_approval(token) do
      {:ok, approval, human, context} ->
        render(conn, :show,
          page_title: "Human approval",
          token: token,
          approval: approval,
          human: human,
          context: context
        )

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> render(:error, page_title: "Approval unavailable", reason: reason)
    end
  end

  def decide(conn, %{"token" => token, "decision" => decision}) do
    case Connections.decide_approval(token, decision) do
      {:ok, approval, effect} ->
        render(conn, :decided,
          page_title: "Decision recorded",
          approval: approval,
          effect: effect
        )

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, page_title: "Approval unavailable", reason: reason)
    end
  end
end
