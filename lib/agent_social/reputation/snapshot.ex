defmodule AgentSocial.Reputation.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "reputation_snapshots" do
    field :human_id, Ecto.UUID
    field :score, :decimal
    field :components, :map, default: %{}
    field :calculated_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:human_id, :score, :components, :calculated_at])
    |> validate_required([:human_id, :score, :components, :calculated_at])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
