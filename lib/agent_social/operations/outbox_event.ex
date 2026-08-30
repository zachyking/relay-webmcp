defmodule AgentSocial.Operations.OutboxEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "outbox_events" do
    field :topic, :string
    field :event_type, :string
    field :resource_type, :string
    field :resource_id, Ecto.UUID
    field :payload, :map, default: %{}
    field :published_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :topic,
      :event_type,
      :resource_type,
      :resource_id,
      :payload,
      :published_at,
      :attempts
    ])
    |> validate_required([:topic, :event_type, :resource_type, :resource_id])
  end
end
