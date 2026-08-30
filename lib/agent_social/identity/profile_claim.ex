defmodule AgentSocial.Identity.ProfileClaim do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "profile_claims" do
    belongs_to :human, AgentSocial.Identity.Human
    field :key, :string
    field :value, :map
    field :visibility, :string, default: "public"
    field :rankable, :boolean, default: true
    timestamps()
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:key, :value, :visibility, :rankable])
    |> validate_required([:key, :value, :visibility])
    |> validate_length(:key, min: 1, max: 64)
    |> validate_inclusion(:visibility, AgentSocial.Types.visibilities())
    |> unique_constraint([:human_id, :key])
  end
end
