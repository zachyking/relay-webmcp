defmodule AgentSocial.Connections.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "threads" do
    field :initiator_human_id, Ecto.UUID
    field :recipient_human_id, Ecto.UUID
    field :relationship_mode, :string
    field :status, :string, default: "active"
    field :last_message_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [
      :initiator_human_id,
      :recipient_human_id,
      :relationship_mode,
      :status,
      :last_message_at
    ])
    |> validate_required([:initiator_human_id, :recipient_human_id, :relationship_mode, :status])
    |> validate_inclusion(:relationship_mode, AgentSocial.Types.relationship_modes())
    |> validate_inclusion(:status, ~w(active closed blocked))
    |> validate_different_people()
  end

  defp validate_different_people(changeset) do
    if get_field(changeset, :initiator_human_id) == get_field(changeset, :recipient_human_id) do
      add_error(changeset, :recipient_human_id, "cannot open a thread with yourself")
    else
      changeset
    end
  end
end
