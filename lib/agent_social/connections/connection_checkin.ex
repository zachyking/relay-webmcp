defmodule AgentSocial.Connections.ConnectionCheckin do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "connection_checkins" do
    field :connection_id, Ecto.UUID
    field :human_id, Ecto.UUID
    field :period_days, :integer
    field :due_at, :utc_datetime_usec
    field :active, :boolean
    field :useful, :boolean
    field :feedback, :map, default: %{}
    field :responded_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(checkin, attrs) do
    checkin
    |> cast(attrs, [
      :connection_id,
      :human_id,
      :period_days,
      :due_at,
      :active,
      :useful,
      :feedback,
      :responded_at
    ])
    |> validate_required([:connection_id, :human_id, :period_days, :due_at])
    |> validate_inclusion(:period_days, [30, 90])
    |> unique_constraint([:connection_id, :human_id, :period_days])
  end
end
