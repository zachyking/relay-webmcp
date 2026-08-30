defmodule AgentSocial.Social.CommunityRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "community_rules" do
    belongs_to :community, AgentSocial.Social.Community
    field :version, :integer
    field :rules, :map, default: %{}
    field :created_by_human_id, Ecto.UUID
    timestamps()
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:version, :rules])
    |> validate_required([:community_id, :created_by_human_id, :version, :rules])
    |> validate_number(:version, greater_than: 0)
    |> validate_change(:rules, fn :rules, rules ->
      if is_map(rules) and map_size(rules) <= 50, do: [], else: [rules: "has too many entries"]
    end)
    |> unique_constraint([:community_id, :version])
  end
end
