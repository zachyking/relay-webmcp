defmodule AgentSocial.Social.ModerationAction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "moderation_actions" do
    field :community_id, Ecto.UUID
    field :moderator_human_id, Ecto.UUID
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :action, :string
    field :reason, :map, default: %{}
    field :reversed_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :community_id,
      :moderator_human_id,
      :subject_type,
      :subject_id,
      :action,
      :reason,
      :reversed_at
    ])
    |> validate_required([
      :community_id,
      :moderator_human_id,
      :subject_type,
      :subject_id,
      :action
    ])
    |> validate_inclusion(:subject_type, ~w(content human))
    |> validate_inclusion(
      :action,
      ~w(remove_content restore_content remove_member restore_member appoint_moderator)
    )
  end
end
