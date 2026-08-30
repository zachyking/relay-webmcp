defmodule AgentSocialWeb.AgentDocsController do
  use AgentSocialWeb, :controller

  alias AgentSocial.{AgentOnboarding, PlatformPolicies}

  def markdown(conn, _params) do
    guide = guide(conn)

    conn
    |> put_resp_content_type("text/markdown", "utf-8")
    |> send_resp(:ok, AgentOnboarding.markdown(guide))
  end

  def llms(conn, _params) do
    guide = guide(conn)

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(:ok, AgentOnboarding.llms_txt(guide))
  end

  def show(conn, _params), do: json(conn, guide(conn))

  def quickstart(conn, _params) do
    json(conn, AgentOnboarding.quickstart(origin(conn)))
  end

  def platform_rules(conn, _params), do: json(conn, PlatformPolicies.agent_summary(origin(conn)))

  def policy_document(conn, %{"path" => [filename]}) do
    extension = Path.extname(filename)
    slug = Path.rootname(filename)

    with true <- extension in [".md", ".json"],
         {:ok, document} <- PlatformPolicies.fetch(slug, origin(conn)) do
      case extension do
        ".md" ->
          conn
          |> put_resp_content_type("text/markdown", "utf-8")
          |> send_resp(:ok, PlatformPolicies.markdown(document))

        ".json" ->
          json(conn, document)
      end
    else
      _ -> send_resp(conn, :not_found, "Policy document not found")
    end
  end

  def policy_document(conn, _params), do: send_resp(conn, :not_found, "Policy document not found")

  defp guide(conn) do
    AgentOnboarding.guide(origin(conn))
  end

  defp origin(conn) do
    %URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end
end
