defmodule AgentSocial.Governance.ConfigurationVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "configuration_versions" do
    field :version, :integer
    field :configuration, :map
    field :status, :string, default: "active"
    field :activated_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [:version, :configuration, :status, :activated_at, :superseded_at])
    |> validate_required([:version, :configuration, :status, :activated_at])
    |> validate_inclusion(:status, ~w(active superseded rolled_back))
    |> unique_constraint(:version)
  end
end
