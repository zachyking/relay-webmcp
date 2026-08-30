defmodule Mix.Tasks.Relay.Smoke do
  use Mix.Task

  @shortdoc "Enrolls an ephemeral agent and smoke-tests the live MCP edge"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, challenge} =
      AgentSocial.Identity.start_enrollment(%{
        "adult_attested" => true,
        "email" => "mcp-smoke-#{suffix}@example.test",
        "handle" => "mcp_smoke_#{suffix}",
        "client_name" => "official-mcp-sdk-smoke",
        "public_key" => Base.url_encode64(public_key, padding: false)
      })

    message = challenge.nonce <> ":" <> challenge.development_otp
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])

    {:ok, enrollment} =
      AgentSocial.Identity.finish_enrollment(%{
        "challenge_id" => challenge.challenge_id,
        "otp" => challenge.development_otp,
        "signature" => Base.url_encode64(signature, padding: false)
      })

    gateway_dir = Path.expand("../../../mcp-gateway", __DIR__)

    try do
      {output, status} =
        System.cmd("npm", ["run", "smoke"],
          cd: gateway_dir,
          env: [{"AGENT_BEARER_TOKEN", enrollment.token}],
          stderr_to_stdout: true
        )

      IO.write(output)
      if status != 0, do: Mix.raise("MCP smoke test failed")
    after
      enrollment.human |> AgentSocial.Repo.delete()
    end
  end
end
