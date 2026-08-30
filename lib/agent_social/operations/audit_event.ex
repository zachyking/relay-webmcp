defmodule AgentSocial.Operations.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "audit_events" do
    field :actor_human_id, Ecto.UUID
    field :agent_binding_id, Ecto.UUID
    field :event_type, :string
    field :resource_type, :string
    field :resource_id, Ecto.UUID
    field :idempotency_key, :string
    field :configuration_version, :integer, default: 1
    field :agent_key_version, :integer
    field :client_id, :string
    field :policy_version, :integer
    field :result_state, :map, default: %{}
    field :metadata, :map, default: %{}
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor_human_id,
      :agent_binding_id,
      :event_type,
      :resource_type,
      :resource_id,
      :idempotency_key,
      :configuration_version,
      :agent_key_version,
      :client_id,
      :policy_version,
      :result_state,
      :metadata
    ])
    |> validate_required([:event_type, :resource_type, :configuration_version])
  end
end
