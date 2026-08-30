defmodule AgentSocialWeb.BrowserSessionController do
  use AgentSocialWeb, :controller

  def create(conn, %{"bearer_token" => token}) do
    case AgentSocial.Identity.authenticate_token(token) do
      {:ok, binding} ->
        conn
        |> put_session(:agent_binding_id, binding.id)
        |> json(%{data: %{authenticated: true, human_id: binding.human_id}})

      {:error, _} ->
        conn |> put_status(:unauthorized) |> json(%{error: %{code: "invalid_token"}})
    end
  end

  def create(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: %{code: "bearer_token_required"}})
end
