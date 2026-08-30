defmodule AgentSocialWeb.HumanController do
  use AgentSocialWeb, :controller

  alias AgentSocial.HumanControls

  def show(conn, %{"token" => token}) do
    with {:ok, human} <- HumanControls.verify_token(token) do
      render(conn, :show,
        page_title: "Human controls",
        token: token,
        snapshot: HumanControls.snapshot(human)
      )
    else
      _ -> unavailable(conn)
    end
  end

  def export(conn, %{"token" => token}) do
    with {:ok, human} <- HumanControls.verify_token(token) do
      filename = "relay-export-#{human.handle}-#{Date.utc_today()}.json"

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, Jason.encode_to_iodata!(HumanControls.export(human), pretty: true))
    else
      _ -> unavailable(conn)
    end
  end

  def revoke_agent(conn, %{"token" => token}) do
    with {:ok, human} <- HumanControls.verify_token(token),
         :ok <- HumanControls.revoke_agent(human) do
      return(conn, token, "Your active agent credential was revoked immediately.")
    else
      _ -> unavailable(conn)
    end
  end

  def end_connection(conn, %{"token" => token, "connection_id" => connection_id}) do
    with {:ok, human} <- HumanControls.verify_token(token),
         :ok <- HumanControls.end_connection(human, connection_id) do
      return(conn, token, "The connection was ended.")
    else
      _ -> unavailable(conn)
    end
  end

  def revoke_grant(conn, %{"token" => token, "grant_id" => grant_id}) do
    with {:ok, human} <- HumanControls.verify_token(token),
         :ok <- HumanControls.revoke_grant(human, grant_id) do
      return(conn, token, "The contact grant was revoked.")
    else
      _ -> unavailable(conn)
    end
  end

  def block(conn, %{"token" => token, "target_human_id" => target_id}) do
    with {:ok, human} <- HumanControls.verify_token(token),
         {:ok, _block} <- HumanControls.block(human, target_id, "human dashboard") do
      return(conn, token, "That person is now blocked across discovery and messaging.")
    else
      _ -> unavailable(conn)
    end
  end

  def report(conn, %{"token" => token, "target_human_id" => target_id} = params) do
    with {:ok, human} <- HumanControls.verify_token(token),
         {:ok, _report} <-
           HumanControls.report(human, target_id, Map.get(params, "category", "other")) do
      return(conn, token, "Your report was recorded for review.")
    else
      _ -> unavailable(conn)
    end
  end

  def delete(conn, %{"token" => token, "confirmation" => "DELETE"}) do
    with {:ok, human} <- HumanControls.verify_token(token),
         {:ok, _result} <- HumanControls.delete_account(human) do
      render(conn, :deleted,
        page_title: "Deletion started",
        purge_date: Date.add(Date.utc_today(), 30)
      )
    else
      _ -> unavailable(conn)
    end
  end

  def delete(conn, %{"token" => token}) do
    return(conn, token, "Type DELETE exactly to confirm account deletion.", :error)
  end

  defp return(conn, token, message, kind \\ :info) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: ~p"/human/#{token}")
  end

  defp unavailable(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(AgentSocialWeb.ErrorHTML)
    |> render(:"404")
  end
end
