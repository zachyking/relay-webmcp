defmodule AgentSocial.Identity.AgentBinding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_bindings" do
    belongs_to :human, AgentSocial.Identity.Human
    field :public_key, :binary
    field :token_digest, :binary
    field :client_name, :string
    field :client_id, :string
    field :scopes, {:array, :string}, default: []
    field :key_version, :integer, default: 1
    field :active, :boolean, default: true
    field :last_seen_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :public_key,
      :token_digest,
      :client_name,
      :client_id,
      :scopes,
      :key_version,
      :active,
      :last_seen_at,
      :revoked_at
    ])
    |> validate_required([:public_key, :token_digest, :client_name, :scopes, :key_version])
    |> validate_change(:public_key, fn :public_key, key ->
      if byte_size(key) == 32, do: [], else: [public_key: "must be exactly 32 bytes"]
    end)
    |> unique_constraint(:human_id, name: :one_active_agent_per_human)
    |> unique_constraint(:token_digest)
  end
end
