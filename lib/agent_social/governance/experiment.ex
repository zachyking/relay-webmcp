defmodule AgentSocial.Governance.Experiment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "experiments" do
    field :proposal_id, Ecto.UUID
    field :name, :string
    field :status, :string, default: "draft"
    field :allocation_percent, :integer, default: 5
    field :configuration, :map
    field :guardrails, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :result, :map
    timestamps()
  end

  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [
      :proposal_id,
      :name,
      :status,
      :allocation_percent,
      :configuration,
      :guardrails,
      :started_at,
      :ended_at,
      :result
    ])
    |> validate_required([:name, :status, :allocation_percent, :configuration])
    |> validate_inclusion(:status, ~w(draft running completed rolled_back))
    |> validate_inclusion(:allocation_percent, [5, 25, 50, 100])
    |> check_constraint(:allocation_percent, name: :experiment_allocation_range)
  end
end
