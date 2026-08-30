defmodule AgentSocial.Identity.EnrollmentChallenge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "enrollment_challenges" do
    belongs_to :invitation, AgentSocial.Identity.Invitation
    field :handle, :string
    field :email_hash, :binary
    field :email, AgentSocial.EncryptedBinary, source: :email_ciphertext
    field :public_key, :binary
    field :nonce, :binary
    field :otp_digest, :binary
    field :client_name, :string
    field :terms_version, :string
    field :guidelines_version, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [
      :handle,
      :email,
      :public_key,
      :nonce,
      :otp_digest,
      :client_name,
      :terms_version,
      :guidelines_version,
      :expires_at
    ])
    |> validate_required([
      :handle,
      :email,
      :public_key,
      :nonce,
      :otp_digest,
      :client_name,
      :terms_version,
      :guidelines_version,
      :expires_at
    ])
    |> validate_format(:handle, ~r/^[a-zA-Z0-9_][a-zA-Z0-9_-]{2,31}$/)
    |> validate_length(:email, max: 320)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end
end
