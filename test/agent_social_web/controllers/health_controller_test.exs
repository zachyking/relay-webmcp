defmodule AgentSocialWeb.HealthControllerTest do
  use AgentSocialWeb.ConnCase

  test "liveness and dependency readiness are public and machine-readable", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/healthz") |> json_response(200)

    assert %{
             "status" => "ready",
             "checks" => %{"postgres" => true, "valkey" => true}
           } = build_conn() |> get(~p"/readyz") |> json_response(200)
  end
end
