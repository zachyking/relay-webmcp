defmodule AgentSocial.Governance.Vote do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "governance_votes" do
    field :proposal_id, Ecto.UUID
    field :human_id, Ecto.UUID
    field :choice, :string
    field :weight, :decimal
    field :reputation_snapshot, :decimal
    timestamps()
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:proposal_id, :human_id, :choice, :weight, :reputation_snapshot])
    |> validate_required([:proposal_id, :human_id, :choice, :weight, :reputation_snapshot])
    |> validate_inclusion(:choice, ~w(support oppose abstain))
    |> unique_constraint([:proposal_id, :human_id])
  end
end
