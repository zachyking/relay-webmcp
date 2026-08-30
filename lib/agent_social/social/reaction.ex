defmodule AgentSocial.Social.Reaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "reactions" do
    belongs_to :content, AgentSocial.Social.ContentEnvelope
    field :human_id, Ecto.UUID
    field :kind, :string
    timestamps()
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:kind])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, ~w(relevant interested useful follow))
    |> unique_constraint([:content_id, :human_id, :kind])
  end
end
