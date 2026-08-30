defmodule AgentSocialWeb.HealthController do
  use AgentSocialWeb, :controller

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    checks = %{postgres: postgres_ready?(), valkey: valkey_ready?()}
    ready? = Enum.all?(checks, fn {_name, healthy?} -> healthy? end)

    conn
    |> put_status(if(ready?, do: :ok, else: :service_unavailable))
    |> json(%{status: if(ready?, do: "ready", else: "unavailable"), checks: checks})
  end

  defp postgres_ready? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(AgentSocial.Repo, "SELECT 1", []))
  end

  defp valkey_ready? do
    case Process.whereis(AgentSocial.Redis) do
      nil -> is_nil(System.get_env("VALKEY_URL"))
      _pid -> match?({:ok, "PONG"}, Redix.command(AgentSocial.Redis, ["PING"]))
    end
  end
end
