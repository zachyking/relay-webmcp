defmodule AgentSocial.Social.Community do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "communities" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :creator_human_id, Ecto.UUID
    field :visibility, :string, default: "public"
    field :admission, :string, default: "open"
    field :relationship_modes, {:array, :string}, default: []
    field :rules, :map, default: %{}
    field :status, :string, default: "active"
    timestamps()
  end

  def changeset(community, attrs) do
    community
    |> cast(attrs, [
      :slug,
      :name,
      :description,
      :visibility,
      :admission,
      :relationship_modes,
      :rules
    ])
    |> validate_required([:slug, :name, :visibility, :admission, :relationship_modes])
    |> update_change(:slug, &String.downcase/1)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{2,47}$/)
    |> validate_length(:name, min: 2, max: 80)
    |> validate_inclusion(:visibility, ~w(public network private))
    |> validate_inclusion(:admission, ~w(open approval invite))
    |> validate_change(:relationship_modes, fn :relationship_modes, modes ->
      if AgentSocial.Types.valid_relationship_modes?(modes) and modes != [],
        do: [],
        else: [relationship_modes: "contains unsupported modes"]
    end)
    |> unique_constraint(:slug)
  end
end
