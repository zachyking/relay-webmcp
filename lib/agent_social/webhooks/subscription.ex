defmodule AgentSocial.Webhooks.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "webhook_subscriptions" do
    belongs_to :human, AgentSocial.Identity.Human
    field :url, :string
    field :secret, AgentSocial.EncryptedBinary, source: :secret_ciphertext
    field :event_types, {:array, :string}, default: []
    field :active, :boolean, default: true
    field :failure_count, :integer, default: 0
    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:url, :secret, :event_types, :active, :failure_count])
    |> validate_required([:url, :secret, :event_types])
    |> validate_length(:url, max: 2_000)
    |> validate_length(:event_types, min: 1, max: 50)
    |> unique_constraint([:human_id, :url])
  end
end
