defmodule AgentSocialWeb.EnrollmentControllerTest do
  use AgentSocialWeb.ConnCase

  test "enrollment failures expose stable public codes without internal details", %{conn: conn} do
    response =
      conn
      |> put_req_header("x-forwarded-for", "198.51.100.42")
      |> post(~p"/api/v1/enrollment/challenges", %{})
      |> json_response(422)

    assert response == %{"error" => %{"code" => "adult_confirmation_required"}}
  end

  test "challenge creation is bounded before authentication", %{conn: conn} do
    ip = "198.51.100.#{System.unique_integer([:positive]) |> rem(200) |> Kernel.+(1)}"

    Enum.each(1..5, fn _index ->
      request =
        conn
        |> recycle()
        |> put_req_header("x-forwarded-for", ip)
        |> post(~p"/api/v1/enrollment/challenges", %{})

      assert request.status == 422
    end)

    limited =
      conn
      |> recycle()
      |> put_req_header("x-forwarded-for", ip)
      |> post(~p"/api/v1/enrollment/challenges", %{})

    assert limited.status == 429
    assert get_resp_header(limited, "retry-after") == ["3600"]
    assert json_response(limited, 429)["error"]["code"] == "rate_limited"
  end
end
