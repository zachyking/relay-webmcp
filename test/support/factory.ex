defmodule AgentSocial.TestFactory do
  alias AgentSocial.Identity.{AgentBinding, ContactField, Human, Policy}
  alias AgentSocial.PlatformPolicies
  alias AgentSocial.Repo

  @scopes ~w(profile:read profile:write feed:read content:write community:write thread:write connection:write governance:write webhook:write)

  def actor(attrs \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic])
    handle = Map.get(attrs, :handle, "person_#{suffix}")
    email = Map.get(attrs, :email, "#{handle}@example.test")
    now = DateTime.utc_now()
    token = "ags_test_#{suffix}_credential"

    human =
      %Human{email_hash: :crypto.hash(:sha256, email)}
      |> Human.changeset(%{
        handle: handle,
        oidc_subject: "oidc_#{suffix}",
        email: email,
        age_attested_at: now,
        verified_at: now,
        terms_version: PlatformPolicies.version(),
        terms_accepted_at: now,
        guidelines_version: PlatformPolicies.version(),
        guidelines_accepted_at: now
      })
      |> Repo.insert!()

    binding =
      %AgentBinding{human_id: human.id}
      |> AgentBinding.changeset(%{
        public_key: :crypto.strong_rand_bytes(32),
        token_digest: :crypto.hash(:sha256, token),
        client_name: Map.get(attrs, :client_name, "test-agent"),
        client_id: "client_#{suffix}",
        scopes: @scopes,
        key_version: 1
      })
      |> Repo.insert!()

    %Policy{human_id: human.id}
    |> Policy.changeset(%{relationship_modes: AgentSocial.Types.relationship_modes()})
    |> Repo.insert!()

    %{human: human, binding: binding, token: token}
  end

  def contact(actor, kind, value) do
    %ContactField{human_id: actor.human.id}
    |> ContactField.changeset(%{kind: kind, value: value})
    |> Repo.insert!()
  end

  def content_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "post",
        "relationship_modes" => ["friendship"],
        "topic_ids" => ["elixir"],
        "visibility" => "public",
        "language" => "en",
        "format" => "text/plain",
        "encoding" => "identity",
        "rankable_metadata" => %{"summary" => "Looking for thoughtful builders"},
        "opaque_payload" => "Untrusted agent-authored content"
      },
      overrides
    )
  end
end
