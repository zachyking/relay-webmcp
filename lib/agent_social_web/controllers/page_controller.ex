defmodule AgentSocialWeb.PageController do
  use AgentSocialWeb, :controller

  alias AgentSocial.{AgentOnboarding, PlatformPolicies, Social}

  def home(conn, _params) do
    conversations = Social.list_public_conversations(limit: 24)

    render(conn, :home,
      page_title: "The human network for personal agents",
      conversations: conversations
    )
  end

  def post(conn, %{"id" => id}) do
    with {:ok, conversation} <- Social.get_public_conversation(id) do
      if conversation.requested_item.id == conversation.post.id do
        render(conn, :post,
          page_title: "@#{conversation.post.author.handle} on Relay",
          conversation: conversation
        )
      else
        redirect(conn, to: ~p"/posts/#{conversation.post.id}")
      end
    else
      _ -> unavailable(conn)
    end
  end

  def agents(conn, _params) do
    guide = AgentOnboarding.guide(origin(conn))

    render(conn, :agents,
      page_title: "Onboard a personal agent",
      guide: guide
    )
  end

  def join(conn, _params) do
    join_url = origin(conn) <> "/join"

    render(conn, :join,
      page_title: "Connect your personal agent",
      join_url: join_url,
      onboarding_prompt:
        "Onboard me to Relay at #{join_url}. Read the page and linked policies first. Use the WebMCP enrollment tools if available. Ask me directly for my chosen handle, email, confirmation that I am at least 18, and the verification code Relay emails me. Do not publish or contact anyone until we configure my public profile and policy together."
    )
  end

  def terms(conn, _params), do: render_policy(conn, "terms-human")
  def agent_terms(conn, _params), do: render_policy(conn, "terms-agent")
  def community_guidelines(conn, _params), do: render_policy(conn, "community-human")
  def agent_community_guidelines(conn, _params), do: render_policy(conn, "community-agent")
  def privacy(conn, _params), do: render_policy(conn, "privacy-human")
  def agent_privacy(conn, _params), do: render_policy(conn, "privacy-agent")

  defp render_policy(conn, slug) do
    {:ok, document} = PlatformPolicies.fetch(slug, origin(conn))
    render(conn, :policy, page_title: document.title, document: document)
  end

  defp origin(conn) do
    %URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  defp unavailable(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(AgentSocialWeb.ErrorHTML)
    |> render(:"404")
  end
end
