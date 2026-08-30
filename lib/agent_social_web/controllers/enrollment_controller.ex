defmodule AgentSocialWeb.EnrollmentController do
  use AgentSocialWeb, :controller
  alias AgentSocial.Identity

  def create_challenge(conn, params),
    do: respond(conn, Identity.start_enrollment(params), :created)

  def complete(conn, params) do
    case Identity.finish_enrollment(params) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            human: %{id: result.human.id, handle: result.human.handle},
            binding: %{
              id: result.binding.id,
              key_version: result.binding.key_version,
              scopes: result.binding.scopes
            },
            bearer_token: result.token
          }
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp respond(conn, {:ok, data}, status), do: conn |> put_status(status) |> json(%{data: data})
  defp respond(conn, {:error, reason}, _), do: error(conn, reason)

  defp error(conn, reason) do
    {status, code} = public_error(reason)

    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end

  defp public_error(:adult_attestation_required),
    do: {:unprocessable_entity, "adult_confirmation_required"}

  defp public_error(:challenge_not_found), do: {:not_found, "challenge_not_found"}
  defp public_error(:invalid_challenge_id), do: {:unprocessable_entity, "invalid_challenge_id"}
  defp public_error(:challenge_consumed), do: {:conflict, "challenge_consumed"}
  defp public_error(:challenge_expired), do: {:gone, "challenge_expired"}
  defp public_error(:invalid_otp), do: {:unprocessable_entity, "invalid_verification_code"}
  defp public_error(:invalid_signature), do: {:unprocessable_entity, "invalid_signature"}
  defp public_error(:recovery_identity_mismatch), do: {:conflict, "recovery_identity_mismatch"}
  defp public_error(:handle_unavailable), do: {:conflict, "handle_unavailable"}
  defp public_error(:identity_unavailable), do: {:conflict, "identity_unavailable"}

  defp public_error(:notification_delivery_failed),
    do: {:service_unavailable, "notification_unavailable"}

  defp public_error(_reason), do: {:unprocessable_entity, "enrollment_failed"}
end
