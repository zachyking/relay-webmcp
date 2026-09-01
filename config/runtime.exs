import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/agent_social start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :agent_social, AgentSocialWeb.Endpoint, server: true
end

if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry, traces_exporter: :otlp
  config :opentelemetry_exporter, otlp_protocol: :http_protobuf
end

config :agent_social, AgentSocialWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :agent_social,
  mcp_public_url: System.get_env("MCP_PUBLIC_URL") || "http://localhost:4001/mcp"

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :agent_social, AgentSocialWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/agent_social_web/router\.ex$"E,
        ~r"lib/agent_social_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  fetch_env! = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  agent_bearer_secret = fetch_env!.("AGENT_BEARER_SECRET")
  mcp_internal_secret = fetch_env!.("MCP_INTERNAL_SECRET")
  mcp_public_url = fetch_env!.("MCP_PUBLIC_URL")
  valkey_url = System.get_env("VALKEY_URL")
  oidc_issuer = System.get_env("OIDC_ISSUER")
  oidc_audience = System.get_env("OIDC_AUDIENCE") || mcp_public_url
  contact_key_encoded = fetch_env!.("CONTACT_ENCRYPTION_KEY")

  config :agent_social, :operator,
    name: fetch_env!.("OPERATOR_NAME"),
    legal_email: fetch_env!.("LEGAL_CONTACT_EMAIL"),
    privacy_email: fetch_env!.("PRIVACY_CONTACT_EMAIL"),
    security_email: fetch_env!.("SECURITY_CONTACT_EMAIL"),
    support_email: fetch_env!.("SUPPORT_CONTACT_EMAIL")

  contact_key =
    case Base.decode64(contact_key_encoded) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> raise "CONTACT_ENCRYPTION_KEY must be a base64-encoded 32-byte key"
    end

  config :agent_social, agent_bearer_secret: agent_bearer_secret
  config :agent_social, :mcp_internal_secret, mcp_internal_secret
  config :agent_social, :mcp_public_url, mcp_public_url

  if is_binary(valkey_url) and valkey_url != "" do
    config :agent_social, :valkey_url, valkey_url
  end

  config :agent_social, :auth,
    issuer: oidc_issuer,
    audience: oidc_audience,
    enrollment_otp_ttl_seconds: 600,
    approval_ttl_seconds: 86_400

  config :agent_social, :embeddings,
    endpoint: System.get_env("EMBEDDING_ENDPOINT"),
    api_key: System.get_env("EMBEDDING_API_KEY"),
    model: System.get_env("EMBEDDING_MODEL") || "text-embedding-3-small",
    dimensions: 768

  notifier_config =
    case System.get_env("NOTIFIER_ADAPTER", "resend") do
      "resend" ->
        endpoint = System.get_env("RESEND_ENDPOINT", "https://api.resend.com/emails")

        unless URI.parse(endpoint).scheme == "https" do
          raise "RESEND_ENDPOINT must use https"
        end

        [
          adapter: AgentSocial.Notifier.ResendAdapter,
          endpoint: endpoint,
          api_key: fetch_env!.("RESEND_API_KEY"),
          from: fetch_env!.("NOTIFIER_FROM")
        ]

      "http" ->
        endpoint = fetch_env!.("NOTIFIER_ENDPOINT")

        unless URI.parse(endpoint).scheme == "https" do
          raise "NOTIFIER_ENDPOINT must use https"
        end

        [
          adapter: AgentSocial.Notifier.HTTPAdapter,
          endpoint: endpoint,
          api_key: fetch_env!.("NOTIFIER_API_KEY")
        ]

      "smtp" ->
        smtp_host = fetch_env!.("SMTP_HOST")
        smtp_port = String.to_integer(System.get_env("SMTP_PORT", "587"))

        tls_options = [
          verify: :verify_peer,
          cacertfile: CAStore.file_path(),
          depth: 4,
          server_name_indication: String.to_charlist(smtp_host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

        transport_options =
          case System.get_env("SMTP_TLS", "starttls") do
            "starttls" ->
              [tls: :always, tls_options: tls_options]

            "ssl" ->
              [ssl: true, sockopts: tls_options]

            unsupported ->
              raise "unsupported SMTP_TLS #{inspect(unsupported)}; expected starttls or ssl"
          end

        config :agent_social,
               AgentSocial.Mailer,
               [
                 adapter: Swoosh.Adapters.SMTP,
                 relay: smtp_host,
                 port: smtp_port,
                 username: fetch_env!.("SMTP_USERNAME"),
                 password: fetch_env!.("SMTP_PASSWORD"),
                 auth: :always,
                 retries: 1
               ] ++ transport_options

        [
          adapter: AgentSocial.Notifier.SMTPAdapter,
          from_address: System.get_env("NOTIFIER_FROM_ADDRESS") || fetch_env!.("SMTP_USERNAME"),
          from_name: System.get_env("NOTIFIER_FROM_NAME", "Relay")
        ]

      unsupported ->
        raise "unsupported NOTIFIER_ADAPTER #{inspect(unsupported)}; expected smtp, resend, or http"
    end

  config :agent_social, AgentSocial.Notifier, notifier_config

  config :agent_social, AgentSocial.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: contact_key
      }
    ]

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :agent_social, AgentSocial.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = fetch_env!.("PHX_HOST")

  config :agent_social, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :agent_social, AgentSocialWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :agent_social, AgentSocialWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :agent_social, AgentSocialWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
