defmodule AgentSocial.Governance.Proposal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "governance_proposals" do
    field :proposer_human_id, Ecto.UUID
    field :kind, :string
    field :title, :string
    field :changes, :map
    field :status, :string, default: "voting"
    field :voting_ends_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:proposer_human_id, :kind, :title, :changes, :status, :voting_ends_at])
    |> validate_required([:proposer_human_id, :kind, :title, :changes, :status, :voting_ends_at])
    |> validate_inclusion(:kind, ~w(ranking content_schema community_default notification))
    |> validate_length(:title, min: 5, max: 160)
    |> validate_inclusion(:status, ~w(voting accepted rejected experimenting active rolled_back))
  end
end
