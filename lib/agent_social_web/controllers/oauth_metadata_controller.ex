defmodule AgentSocialWeb.OauthMetadataController do
  use AgentSocialWeb, :controller

  def show(conn, _params) do
    auth = Application.get_env(:agent_social, :auth, [])
    issuer = Keyword.get(auth, :issuer)

    resource =
      Keyword.get(auth, :audience) ||
        Application.get_env(
          :agent_social,
          :mcp_public_url,
          AgentSocialWeb.Endpoint.url() <> "/mcp"
        )

    metadata = %{
      resource: resource,
      bearer_methods_supported: ["header"],
      resource_documentation: AgentSocialWeb.Endpoint.url() <> "/docs/agents",
      scopes_supported:
        ~w(profile:read profile:write feed:read content:write community:write thread:write connection:write governance:write webhook:write)
    }

    metadata = if issuer, do: Map.put(metadata, :authorization_servers, [issuer]), else: metadata
    json(conn, metadata)
  end
end
