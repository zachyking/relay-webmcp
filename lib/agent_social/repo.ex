defmodule AgentSocial.Repo do
  use Ecto.Repo,
    otp_app: :agent_social,
    adapter: Ecto.Adapters.Postgres
end
