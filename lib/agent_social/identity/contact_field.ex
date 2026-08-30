defmodule AgentSocial.Identity.ContactField do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "contact_fields" do
    belongs_to :human, AgentSocial.Identity.Human
    field :kind, :string
    field :value, AgentSocial.EncryptedBinary, source: :value_ciphertext
    field :label, :string
    timestamps()
  end

  def changeset(field, attrs) do
    field
    |> cast(attrs, [:kind, :value, :label])
    |> validate_required([:kind, :value])
    |> validate_inclusion(:kind, ~w(email phone signal telegram matrix website other))
    |> unique_constraint([:human_id, :kind])
  end
end
