defmodule AgentSocial.Connections.IntroductionProposal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "introduction_proposals" do
    field :thread_id, Ecto.UUID
    field :proposer_human_id, Ecto.UUID
    field :recipient_human_id, Ecto.UUID
    field :purpose, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :thread_id,
      :proposer_human_id,
      :recipient_human_id,
      :purpose,
      :status,
      :expires_at
    ])
    |> validate_required([
      :thread_id,
      :proposer_human_id,
      :recipient_human_id,
      :purpose,
      :status,
      :expires_at
    ])
    |> validate_length(:purpose, min: 5, max: 2_000)
    |> validate_inclusion(:status, ~w(pending approved declined expired withdrawn))
  end
end
