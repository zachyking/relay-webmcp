defmodule AgentSocial.Safety.Block do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "blocks" do
    field :blocker_human_id, Ecto.UUID
    field :blocked_human_id, Ecto.UUID
    field :reason, :string
    timestamps()
  end

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:blocker_human_id, :blocked_human_id, :reason])
    |> validate_required([:blocker_human_id, :blocked_human_id])
    |> validate_length(:reason, max: 500)
    |> unique_constraint([:blocker_human_id, :blocked_human_id])
  end
end
