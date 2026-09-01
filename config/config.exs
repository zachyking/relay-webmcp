# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :agent_social,
  ecto_repos: [AgentSocial.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  reveal_enrollment_otp: config_env() != :prod,
  reveal_approval_tokens: config_env() != :prod,
  human_control_token_max_age: 3_600

config :agent_social, AgentSocial.Repo, types: AgentSocial.PostgrexTypes

config :agent_social, Oban,
  repo: AgentSocial.Repo,
  queues: [default: 10, webhooks: 20, lifecycle: 5, discovery: 5, governance: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", AgentSocial.Operations.InboxDispatchWorker},
       {"0 2 1 * *", AgentSocial.Operations.PartitionWorker},
       {"0 * * * *", AgentSocial.Reputation.RecalculationWorker},
       {"17 * * * *", AgentSocial.Operations.IdempotencyCleanupWorker},
       {"7 * * * *", AgentSocial.Identity.EnrollmentCleanupWorker},
       {"*/5 * * * *", AgentSocial.Governance.EvaluationWorker}
     ]}
  ]

config :agent_social, :embeddings,
  endpoint: System.get_env("EMBEDDING_ENDPOINT"),
  api_key: System.get_env("EMBEDDING_API_KEY"),
  model: System.get_env("EMBEDDING_MODEL") || "text-embedding-3-small",
  dimensions: 768

config :agent_social, :rate_limits,
  window_seconds: 60,
  reads_per_window: 600,
  writes_per_window: 120

config :agent_social, :enrollment_rate_limits,
  window_seconds: 3_600,
  challenges_per_window: 5,
  completions_per_window: 20,
  sessions_per_window: 30

config :agent_social, AgentSocial.Notifier, adapter: AgentSocial.Notifier.LogAdapter
config :agent_social, AgentSocial.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

config :agent_social, :operator,
  name: "dzcodes.dev",
  legal_email: "legal@relay.invalid",
  privacy_email: "privacy@relay.invalid",
  security_email: "security@relay.invalid",
  support_email: "support@relay.invalid"

config :agent_social,
  agent_bearer_secret:
    System.get_env("AGENT_BEARER_SECRET") ||
      "development-agent-bearer-secret-change-before-production"

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :none,
  resource: %{
    "service.name" => "relay-core",
    "service.version" => "0.1.0",
    "service.namespace" => "agent-social"
  }

config :agent_social, AgentSocial.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key:
        Base.decode64!(
          System.get_env("CONTACT_ENCRYPTION_KEY") ||
            "c3RhdGljLWRldmVudC1rZXktMzItYnl0ZXMtMTIzNDU="
        )
    }
  ]

config :agent_social, :auth,
  issuer: System.get_env("OIDC_ISSUER"),
  audience: System.get_env("OIDC_AUDIENCE") || "http://localhost:4001/mcp",
  enrollment_otp_ttl_seconds: 600,
  approval_ttl_seconds: 86_400

# Configure the endpoint
config :agent_social, AgentSocialWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AgentSocialWeb.ErrorHTML, json: AgentSocialWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AgentSocial.PubSub,
  live_view: [signing_salt: "Ay8CMLT0"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  agent_social: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  agent_social: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
