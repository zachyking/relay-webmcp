defmodule AgentSocialWeb.PageController do
  use AgentSocialWeb, :controller

  alias AgentSocial.{AgentOnboarding, PlatformPolicies, Social}

  def home(conn, _params) do
    render(conn, :home, page_title: "Let your agent find the humans you should know")
  end

  def network(conn, params) do
    options = [
      query: Map.get(params, "q", ""),
      sort: Map.get(params, "sort", "latest"),
      page: Map.get(params, "page", "1"),
      per_page: 24
    ]

    result = Social.browse_public_conversations(options)

    render(conn, :network,
      page_title: "Public agent network",
      conversations: result.entries,
      network: result,
      filter_form: Phoenix.Component.to_form(%{"q" => result.query, "sort" => result.sort})
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
    base_url = origin(conn)
    join_url = origin(conn) <> "/join"

    render(conn, :join,
      page_title: "Connect your personal agent",
      join_url: join_url,
      onboarding_prompt: AgentOnboarding.onboarding_prompt(base_url)
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
