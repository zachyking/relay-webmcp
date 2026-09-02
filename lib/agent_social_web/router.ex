defmodule AgentSocialWeb.Router do
  use AgentSocialWeb, :router

  @browser_security_headers %{
    "content-security-policy" =>
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'",
    "permissions-policy" =>
      "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=()",
    "referrer-policy" => "strict-origin-when-cross-origin"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AgentSocialWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @browser_security_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :agent_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug AgentSocialWeb.Plugs.AgentAuth
    plug AgentSocialWeb.Plugs.AgentRateLimit
    plug AgentSocialWeb.Plugs.AgentIdempotency
  end

  pipeline :enrollment_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug AgentSocialWeb.Plugs.EnrollmentRateLimit
  end

  pipeline :public_document do
    plug :put_secure_browser_headers, @browser_security_headers
  end

  scope "/", AgentSocialWeb do
    pipe_through :public_document

    get "/llms.txt", AgentDocsController, :llms
    get "/docs/agents.md", AgentDocsController, :markdown
    get "/agent-onboarding.json", AgentDocsController, :show
    get "/policies/*path", AgentDocsController, :policy_document
  end

  scope "/", AgentSocialWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/network", PageController, :network
    get "/studio", PageController, :studio
    get "/studio/review", PageController, :studio
    get "/join", PageController, :join
    get "/docs/agents", PageController, :agents
    get "/terms", PageController, :terms
    get "/terms/agents", PageController, :agent_terms
    get "/community-guidelines", PageController, :community_guidelines
    get "/community-guidelines/agents", PageController, :agent_community_guidelines
    get "/privacy", PageController, :privacy
    get "/privacy/agents", PageController, :agent_privacy
    get "/posts/:id", PageController, :post
    get "/approvals/:token", ApprovalController, :show
    post "/approvals/:token", ApprovalController, :decide
    get "/human-access", HumanController, :access
    post "/human-access", HumanController, :send_link
    get "/human/:token", HumanController, :show
    get "/human/:token/export", HumanController, :export
    post "/human/:token/revoke-agent", HumanController, :revoke_agent
    post "/human/:token/connections/:connection_id/end", HumanController, :end_connection
    post "/human/:token/grants/:grant_id/revoke", HumanController, :revoke_grant
    post "/human/:token/block", HumanController, :block
    post "/human/:token/report", HumanController, :report
    post "/human/:token/delete", HumanController, :delete
  end

  scope "/", AgentSocialWeb do
    pipe_through :api

    get "/healthz", HealthController, :live
    get "/readyz", HealthController, :ready
    get "/.well-known/oauth-protected-resource", OauthMetadataController, :show
    get "/api/v1/onboarding", AgentDocsController, :quickstart
    get "/api/v1/platform-rules", AgentDocsController, :platform_rules
    get "/api/v1/studio-review", StudioReviewController, :show
    put "/api/v1/studio-review", StudioReviewController, :update
    post "/api/v1/studio-review/ready", StudioReviewController, :ready
    post "/api/v1/studio-review/publish", StudioReviewController, :publish
  end

  scope "/", AgentSocialWeb do
    pipe_through :enrollment_api

    post "/api/v1/enrollment/challenges", EnrollmentController, :create_challenge
    post "/api/v1/enrollment/complete", EnrollmentController, :complete
    post "/api/v1/browser-session", BrowserSessionController, :create
  end

  scope "/api/v1", AgentSocialWeb do
    pipe_through :agent_api

    get "/whoami", AgentController, :profile_get
    get "/profiles/me", AgentController, :profile_get
    get "/profiles/:id", AgentController, :profile_show
    put "/profiles/me/claims", AgentController, :profile_update
    put "/profiles/me/contact-fields", AgentController, :contact_field_set
    get "/policies/me", AgentController, :policy_get
    put "/policies/me", AgentController, :policy_set
    get "/feed", AgentController, :feed_browse
    get "/search", AgentController, :network_search
    get "/items/:id", AgentController, :item_get
    post "/posts", AgentController, :post_publish
    post "/studio-sessions", StudioSessionController, :create
    get "/studio-sessions/:id", StudioSessionController, :show
    put "/studio-sessions/:id", StudioSessionController, :revise
    post "/studio-sessions/:id/publish", StudioSessionController, :publish
    post "/posts/:id/replies", AgentController, :post_reply
    put "/items/:id/reactions", AgentController, :reaction_set
    post "/communities", AgentController, :community_create
    post "/communities/:id/join", AgentController, :community_join
    put "/communities/:id/rules", AgentController, :community_rules_set
    post "/communities/:id/moderate", AgentController, :community_moderate
    post "/threads", AgentController, :thread_open
    get "/threads/:id/messages", AgentController, :thread_messages
    post "/threads/:id/messages", AgentController, :thread_send
    post "/introductions", AgentController, :intro_propose
    post "/introductions/:id/respond", AgentController, :intro_respond
    post "/contacts/requests", AgentController, :contact_request
    get "/connections/:connection_id/contacts", AgentController, :contact_get
    post "/connection-checkins/:id", AgentController, :connection_checkin
    get "/inbox", AgentController, :inbox_read
    put "/webhooks", AgentController, :webhook_set
    post "/governance/proposals", AgentController, :governance_propose
    post "/governance/proposals/:id/votes", AgentController, :governance_vote
    post "/blocks", AgentController, :block
    post "/reports", AgentController, :report
    post "/identity/revoke", AgentController, :revoke
    delete "/identity", AgentController, :delete_account
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:agent_social, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AgentSocialWeb.Telemetry
    end
  end
end
