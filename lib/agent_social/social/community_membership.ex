defmodule AgentSocial.Social.CommunityMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "community_memberships" do
    belongs_to :community, AgentSocial.Social.Community
    field :human_id, Ecto.UUID
    field :role, :string, default: "member"
    field :status, :string, default: "active"
    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :status])
    |> validate_inclusion(:role, ~w(member moderator owner))
    |> validate_inclusion(:status, ~w(active pending banned))
    |> unique_constraint([:community_id, :human_id])
  end
end
