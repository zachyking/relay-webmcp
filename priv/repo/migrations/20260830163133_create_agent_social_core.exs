defmodule AgentSocial.Repo.Migrations.CreateAgentSocialCore do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"
    Oban.Migrations.up(version: 14)

    create table(:invitations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :code_digest, :binary, null: false
      add :created_by_id, :uuid
      add :max_uses, :integer, null: false, default: 1
      add :use_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invitations, [:code_digest])

    create table(:humans, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :handle, :citext, null: false
      add :oidc_subject, :string
      add :email_hash, :binary, null: false
      add :email_ciphertext, :binary, null: false
      add :age_attested_at, :utc_datetime_usec, null: false
      add :verified_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "active"
      add :reputation, :decimal, null: false, default: 20
      add :deleted_at, :utc_datetime_usec
      add :purge_after, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:humans, [:handle])
    create unique_index(:humans, [:oidc_subject], where: "oidc_subject IS NOT NULL")
    create unique_index(:humans, [:email_hash])

    create constraint(:humans, :humans_reputation_range,
             check: "reputation >= 0 AND reputation <= 100"
           )

    create table(:enrollment_challenges, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :invitation_id, references(:invitations, type: :uuid, on_delete: :delete_all),
        null: false

      add :handle, :citext, null: false
      add :email_hash, :binary, null: false
      add :email_ciphertext, :binary, null: false
      add :public_key, :binary, null: false
      add :nonce, :binary, null: false
      add :otp_digest, :binary, null: false
      add :client_name, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:enrollment_challenges, [:email_hash])

    create table(:agent_bindings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :public_key, :binary, null: false
      add :token_digest, :binary, null: false
      add :client_name, :string, null: false
      add :client_id, :string
      add :scopes, {:array, :string}, null: false, default: []
      add :key_version, :integer, null: false, default: 1
      add :active, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_bindings, [:token_digest])

    create unique_index(:agent_bindings, [:human_id],
             where: "active = true",
             name: :one_active_agent_per_human
           )

    create table(:policies, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :relationship_modes, {:array, :string}, null: false, default: []
      add :topic_preferences, {:array, :string}, null: false, default: []
      add :daily_post_limit, :integer, null: false, default: 20
      add :daily_message_limit, :integer, null: false, default: 200
      add :allow_inbound_threads, :boolean, null: false, default: true
      add :require_intro_approval, :boolean, null: false, default: true
      add :require_contact_approval, :boolean, null: false, default: true
      add :disclosure_rules, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:policies, [:human_id])

    create table(:profile_claims, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :map, null: false
      add :visibility, :string, null: false, default: "network"
      add :rankable, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profile_claims, [:human_id, :key])
    create index(:profile_claims, [:visibility])

    create table(:contact_fields, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :value_ciphertext, :binary, null: false
      add :label, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:contact_fields, [:human_id, :kind])

    create table(:communities, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :slug, :citext, null: false
      add :name, :string, null: false
      add :description, :text
      add :creator_human_id, references(:humans, type: :uuid, on_delete: :nilify_all), null: false
      add :visibility, :string, null: false, default: "network"
      add :admission, :string, null: false, default: "open"
      add :rules, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:communities, [:slug])

    create table(:community_memberships, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :community_id, references(:communities, type: :uuid, on_delete: :delete_all),
        null: false

      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:community_memberships, [:community_id, :human_id])

    create table(:moderation_actions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :community_id, references(:communities, type: :uuid, on_delete: :delete_all),
        null: false

      add :moderator_human_id, references(:humans, type: :uuid, on_delete: :nilify_all),
        null: false

      add :subject_type, :string, null: false
      add :subject_id, :uuid, null: false
      add :action, :string, null: false
      add :reason, :map, null: false, default: %{}
      add :reversed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:moderation_actions, [:community_id, :inserted_at])

    create table(:content_envelopes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :author_human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :agent_binding_id, references(:agent_bindings, type: :uuid, on_delete: :nilify_all)
      add :community_id, references(:communities, type: :uuid, on_delete: :nilify_all)
      add :parent_id, references(:content_envelopes, type: :uuid, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :relationship_modes, {:array, :string}, null: false, default: []
      add :topic_ids, {:array, :string}, null: false, default: []
      add :visibility, :string, null: false, default: "network"
      add :language, :string, null: false, default: "en"
      add :format, :string, null: false, default: "text/plain"
      add :encoding, :string, null: false, default: "identity"
      add :schema_uri, :string
      add :rankable_metadata, :map, null: false, default: %{}
      add :opaque_payload, :text, null: false
      add :search_document, :tsvector
      add :embedding, :vector, size: 768
      add :provenance, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:content_envelopes, :opaque_payload_max_bytes,
             check: "octet_length(opaque_payload) <= 32768"
           )

    create index(:content_envelopes, [:author_human_id, :inserted_at])
    create index(:content_envelopes, [:community_id, :inserted_at])
    create index(:content_envelopes, [:parent_id])
    create index(:content_envelopes, [:visibility, :inserted_at])

    execute "CREATE INDEX content_search_idx ON content_envelopes USING GIN (search_document)",
            "DROP INDEX content_search_idx"

    execute """
            CREATE FUNCTION content_search_document_update() RETURNS trigger AS $$
            BEGIN
              NEW.search_document := to_tsvector('simple', coalesce(NEW.rankable_metadata::text, ''));
              RETURN NEW;
            END
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION IF EXISTS content_search_document_update()"

    execute """
            CREATE TRIGGER content_search_document_trigger
              BEFORE INSERT OR UPDATE OF rankable_metadata ON content_envelopes
              FOR EACH ROW EXECUTE FUNCTION content_search_document_update()
            """,
            "DROP TRIGGER IF EXISTS content_search_document_trigger ON content_envelopes"

    create table(:reactions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :content_id, references(:content_envelopes, type: :uuid, on_delete: :delete_all),
        null: false

      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:reactions, [:content_id, :human_id, :kind])

    create table(:threads, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :initiator_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :recipient_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :relationship_mode, :string, null: false
      add :status, :string, null: false, default: "active"
      add :last_message_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:threads, [:initiator_human_id, :recipient_human_id, :relationship_mode])

    create table(:messages, primary_key: false, options: "PARTITION BY RANGE (inserted_at)") do
      add :id, :uuid, null: false
      add :thread_id, references(:threads, type: :uuid, on_delete: :delete_all), null: false
      add :sender_human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :agent_binding_id, references(:agent_bindings, type: :uuid, on_delete: :nilify_all)
      add :format, :string, null: false, default: "text/plain"
      add :encoding, :string, null: false, default: "identity"
      add :schema_uri, :string
      add :opaque_payload, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:messages, :message_payload_max_bytes,
             check: "octet_length(opaque_payload) <= 32768"
           )

    create index(:messages, [:thread_id, :inserted_at])
    create index(:messages, [:id])
    create_monthly_partitions("messages")

    create table(:introduction_proposals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :thread_id, references(:threads, type: :uuid, on_delete: :delete_all), null: false

      add :proposer_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :recipient_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :purpose, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:human_approvals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :uuid, null: false
      add :recipient_human_id, references(:humans, type: :uuid, on_delete: :delete_all)
      add :fields, {:array, :string}, null: false, default: []
      add :token_digest, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      add :decided_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_approvals, [:token_digest])
    create index(:human_approvals, [:resource_type, :resource_id])

    create table(:connections, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :introduction_id,
          references(:introduction_proposals, type: :uuid, on_delete: :delete_all), null: false

      add :human_a_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :human_b_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :relationship_mode, :string, null: false
      add :status, :string, null: false, default: "active"
      add :activated_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connections, [:introduction_id])

    create table(:contact_grants, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :owner_human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false

      add :recipient_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :connection_id, references(:connections, type: :uuid, on_delete: :delete_all),
        null: false

      add :field_ids, {:array, :uuid}, null: false, default: []
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create table(:connection_checkins, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :connection_id, references(:connections, type: :uuid, on_delete: :delete_all),
        null: false

      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :period_days, :integer, null: false
      add :due_at, :utc_datetime_usec, null: false
      add :active, :boolean
      add :useful, :boolean
      add :feedback, :map, null: false, default: %{}
      add :responded_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connection_checkins, [:connection_id, :human_id, :period_days])

    create table(:blocks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :blocker_human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :blocked_human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:blocks, [:blocker_human_id, :blocked_human_id])

    create table(:reports, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :reporter_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :subject_type, :string, null: false
      add :subject_id, :uuid, null: false
      add :category, :string, null: false
      add :details, :map, null: false, default: %{}
      add :status, :string, null: false, default: "open"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:reports, [:status, :inserted_at])

    create table(:inbox_events, primary_key: false, options: "PARTITION BY RANGE (inserted_at)") do
      add :id, :uuid, null: false
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :uuid, null: false
      add :metadata, :map, null: false, default: %{}
      add :read_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:inbox_events, [:human_id, :inserted_at, :id])
    create index(:inbox_events, [:id])
    create_monthly_partitions("inbox_events")

    create table(:webhook_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :secret_ciphertext, :binary, null: false
      add :event_types, {:array, :string}, null: false, default: []
      add :active, :boolean, null: false, default: true
      add :failure_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_subscriptions, [:human_id, :url])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subscription_id,
          references(:webhook_subscriptions, type: :uuid, on_delete: :delete_all), null: false

      add :outbox_event_id, :uuid
      add :event_id, :uuid, null: false
      add :event_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :last_status, :integer
      add :last_error, :text
      add :delivered_at, :utc_datetime_usec
      add :next_attempt_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_deliveries, [:subscription_id, :event_id])
    create index(:webhook_deliveries, [:status, :next_attempt_at])

    create table(:governance_proposals, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :proposer_human_id, references(:humans, type: :uuid, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :title, :string, null: false
      add :changes, :map, null: false
      add :status, :string, null: false, default: "voting"
      add :voting_ends_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:governance_votes, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :proposal_id, references(:governance_proposals, type: :uuid, on_delete: :delete_all),
        null: false

      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :choice, :string, null: false
      add :weight, :decimal, null: false
      add :reputation_snapshot, :decimal, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_votes, [:proposal_id, :human_id])

    create table(:reputation_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :score, :decimal, null: false
      add :components, :map, null: false, default: %{}
      add :calculated_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:reputation_snapshots, [:human_id, :calculated_at])

    create table(:experiments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :proposal_id, references(:governance_proposals, type: :uuid, on_delete: :nilify_all)
      add :name, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :allocation_percent, :integer, null: false, default: 5
      add :configuration, :map, null: false
      add :guardrails, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :result, :map
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:experiments, :experiment_allocation_range,
             check: "allocation_percent >= 0 AND allocation_percent <= 100"
           )

    create table(:configuration_versions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :version, :integer, null: false
      add :configuration, :map, null: false
      add :status, :string, null: false, default: "active"
      add :activated_at, :utc_datetime_usec, null: false
      add :superseded_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:configuration_versions, [:version])

    create unique_index(:configuration_versions, [:status],
             where: "status = 'active'",
             name: :one_active_configuration
           )

    create table(:idempotency_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false
      add :operation, :string, null: false
      add :key, :string, null: false
      add :request_hash, :binary, null: false
      add :response_status, :integer
      add :response_body, :map
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_keys, [:human_id, :operation, :key])

    create table(:audit_events, primary_key: false, options: "PARTITION BY RANGE (inserted_at)") do
      add :id, :uuid, null: false
      add :actor_human_id, references(:humans, type: :uuid, on_delete: :nilify_all)
      add :agent_binding_id, references(:agent_bindings, type: :uuid, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :uuid
      add :idempotency_key, :string
      add :configuration_version, :integer, null: false, default: 1
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:actor_human_id, :inserted_at])
    create index(:audit_events, [:id])
    create_monthly_partitions("audit_events")

    create table(:outbox_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :topic, :string, null: false
      add :event_type, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :uuid, null: false
      add :payload, :map, null: false, default: %{}
      add :published_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:outbox_events, [:published_at, :inserted_at])
  end

  def down do
    drop table(:outbox_events)
    drop table(:audit_events)
    drop table(:idempotency_keys)
    drop table(:configuration_versions)
    drop table(:experiments)
    drop table(:reputation_snapshots)
    drop table(:governance_votes)
    drop table(:governance_proposals)
    drop table(:webhook_deliveries)
    drop table(:webhook_subscriptions)
    drop table(:inbox_events)
    drop table(:reports)
    drop table(:blocks)
    drop table(:connection_checkins)
    drop table(:contact_grants)
    drop table(:connections)
    drop table(:human_approvals)
    drop table(:introduction_proposals)
    drop table(:messages)
    drop table(:threads)
    drop table(:reactions)
    drop table(:content_envelopes)
    drop table(:moderation_actions)
    drop table(:community_memberships)
    drop table(:communities)
    drop table(:contact_fields)
    drop table(:profile_claims)
    drop table(:policies)
    drop table(:agent_bindings)
    drop table(:enrollment_challenges)
    drop table(:humans)
    drop table(:invitations)
    Oban.Migrations.down(version: 1)
  end

  defp create_monthly_partitions(table) do
    Enum.each(0..71, fn offset ->
      from = month_offset(~D[2025-01-01], offset)
      until = month_offset(~D[2025-01-01], offset + 1)
      suffix = Calendar.strftime(from, "%Y_%m")

      execute("""
      CREATE TABLE #{table}_#{suffix} PARTITION OF #{table}
      FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(until)}')
      """)
    end)
  end

  defp month_offset(%Date{year: year, month: month}, offset) do
    absolute_month = year * 12 + month - 1 + offset
    Date.new!(div(absolute_month, 12), rem(absolute_month, 12) + 1, 1)
  end
end
