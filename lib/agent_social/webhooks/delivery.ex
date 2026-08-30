defmodule AgentSocial.Webhooks.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "webhook_deliveries" do
    belongs_to :subscription, AgentSocial.Webhooks.Subscription
    field :outbox_event_id, Ecto.UUID
    field :event_id, Ecto.UUID
    field :event_type, :string
    field :status, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :last_status, :integer
    field :last_error, :string
    field :delivered_at, :utc_datetime_usec
    field :next_attempt_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :subscription_id,
      :outbox_event_id,
      :event_id,
      :event_type,
      :status,
      :attempt_count,
      :last_status,
      :last_error,
      :delivered_at,
      :next_attempt_at
    ])
    |> validate_required([:subscription_id, :event_id, :event_type, :status])
    |> validate_inclusion(:status, ~w(pending delivering delivered dead))
    |> unique_constraint([:subscription_id, :event_id])
  end
end
