defmodule AgentSocial.Connections.Connection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "connections" do
    field :introduction_id, Ecto.UUID
    field :human_a_id, Ecto.UUID
    field :human_b_id, Ecto.UUID
    field :relationship_mode, :string
    field :status, :string, default: "active"
    field :activated_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :introduction_id,
      :human_a_id,
      :human_b_id,
      :relationship_mode,
      :status,
      :activated_at
    ])
    |> validate_required([
      :introduction_id,
      :human_a_id,
      :human_b_id,
      :relationship_mode,
      :status,
      :activated_at
    ])
    |> validate_inclusion(:relationship_mode, AgentSocial.Types.relationship_modes())
    |> validate_inclusion(:status, ~w(active ended blocked))
    |> unique_constraint(:introduction_id)
  end
end
