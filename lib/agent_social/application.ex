defmodule AgentSocial.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:agent_social, :repo], db_statement: :disabled)
    OpentelemetryOban.setup()

    valkey_children =
      case System.get_env("VALKEY_URL") do
        url when is_binary(url) and url != "" -> [{Redix, {url, [name: AgentSocial.Redis]}}]
        _ -> []
      end

    children =
      valkey_children ++
        [
          AgentSocialWeb.Telemetry,
          AgentSocial.Repo,
          AgentSocial.Vault,
          AgentSocial.RateLimiter,
          {Oban, Application.fetch_env!(:agent_social, Oban)},
          {DNSCluster, query: Application.get_env(:agent_social, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: AgentSocial.PubSub},
          # Start a worker by calling: AgentSocial.Worker.start_link(arg)
          # {AgentSocial.Worker, arg},
          # Start to serve requests, typically the last entry
          AgentSocialWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentSocial.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentSocialWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
