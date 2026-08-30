defmodule AgentSocial.SecurityAndLifecycleTest do
  use AgentSocial.DataCase

  alias AgentSocial.Identity
  alias AgentSocial.Identity.{AgentBinding, ContactField, Human, Policy}
  alias AgentSocial.Lifecycle.DeletionWorker
  alias AgentSocial.Operations.AuditEvent
  alias AgentSocial.RateLimiter
  alias AgentSocial.Social.ContentEnvelope
  alias AgentSocial.Webhooks.URLPolicy

  test "webhook destinations reject local, private, credentialed, and non-TLS URLs" do
    assert {:error, :unsafe_webhook_url} = URLPolicy.validate("http://1.1.1.1/hook")
    assert {:error, :unsafe_webhook_url} = URLPolicy.validate("https://127.0.0.1/hook")
    assert {:error, :unsafe_webhook_url} = URLPolicy.validate("https://[::1]/hook")
    assert {:error, :unsafe_webhook_url} = URLPolicy.validate("https://10.0.0.1/hook")
    assert {:error, :unsafe_webhook_url} = URLPolicy.validate("https://user:pass@1.1.1.1/hook")
    assert :ok = URLPolicy.validate("https://1.1.1.1/hook")
  end

  test "rate limits fail closed after the configured allowance" do
    key = "test-rate-#{Ecto.UUID.generate()}"
    assert :ok = RateLimiter.check(key, 2, 60)
    assert :ok = RateLimiter.check(key, 2, 60)
    assert {:error, :rate_limited, 60} = RateLimiter.check(key, 2, 60)
  end

  test "deletion purges identity and social data while retaining a de-identified audit proof" do
    owner = actor()
    contact(owner, "email", "purge-me@example.test")

    {:ok, content} =
      AgentSocial.Social.publish(owner.binding, content_attrs(), "purge-content-key")

    assert {:ok, _} = Identity.delete_account(owner.binding)

    Human
    |> Repo.get!(owner.human.id)
    |> Ecto.Changeset.change(purge_after: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert :ok = DeletionWorker.perform(%Oban.Job{args: %{"human_id" => owner.human.id}})

    refute Repo.get(Human, owner.human.id)
    refute Repo.get(AgentBinding, owner.binding.id)
    refute Repo.get(ContentEnvelope, content.id)
    refute Repo.get_by(ContactField, human_id: owner.human.id)
    refute Repo.get_by(Policy, human_id: owner.human.id)

    audit =
      Repo.get_by!(AuditEvent,
        event_type: "identity.deletion_started",
        resource_id: owner.human.id
      )

    assert is_nil(audit.actor_human_id)
    assert is_nil(audit.agent_binding_id)
  end
end
