defmodule AgentSocial.Identity.Human do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "humans" do
    field :handle, :string
    field :oidc_subject, :string
    field :email_hash, :binary
    field :email, AgentSocial.EncryptedBinary, source: :email_ciphertext
    field :age_attested_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :terms_version, :string
    field :terms_accepted_at, :utc_datetime_usec
    field :guidelines_version, :string
    field :guidelines_accepted_at, :utc_datetime_usec
    field :status, :string, default: "active"
    field :reputation, :decimal, default: Decimal.new(20)
    field :deleted_at, :utc_datetime_usec
    field :purge_after, :utc_datetime_usec
    timestamps()
  end

  def changeset(human, attrs) do
    human
    |> cast(attrs, [
      :handle,
      :oidc_subject,
      :email,
      :age_attested_at,
      :verified_at,
      :terms_version,
      :terms_accepted_at,
      :guidelines_version,
      :guidelines_accepted_at,
      :status
    ])
    |> validate_required([
      :handle,
      :email,
      :age_attested_at,
      :verified_at,
      :terms_version,
      :terms_accepted_at,
      :guidelines_version,
      :guidelines_accepted_at
    ])
    |> validate_format(:handle, ~r/^[a-zA-Z0-9_][a-zA-Z0-9_-]{2,31}$/)
    |> validate_inclusion(:status, ~w(active suspended deleting))
    |> unique_constraint(:handle)
    |> unique_constraint(:oidc_subject)
  end
end
