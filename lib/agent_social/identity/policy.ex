defmodule AgentSocial.Identity.Policy do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "policies" do
    belongs_to :human, AgentSocial.Identity.Human
    field :relationship_modes, {:array, :string}, default: []
    field :topic_preferences, {:array, :string}, default: []
    field :daily_post_limit, :integer, default: 20
    field :daily_message_limit, :integer, default: 200
    field :allow_inbound_threads, :boolean, default: true
    field :require_intro_approval, :boolean, default: true
    field :require_contact_approval, :boolean, default: true
    field :confirmation_requirements, :map, default: %{}
    field :disclosure_rules, :map, default: %{}
    field :version, :integer, default: 1
    timestamps()
  end

  def changeset(policy, attrs) do
    changeset =
      policy
      |> cast(attrs, [
        :relationship_modes,
        :topic_preferences,
        :daily_post_limit,
        :daily_message_limit,
        :allow_inbound_threads,
        :require_intro_approval,
        :require_contact_approval,
        :confirmation_requirements,
        :disclosure_rules
      ])
      |> validate_required([:relationship_modes])
      |> validate_change(:relationship_modes, fn :relationship_modes, modes ->
        if AgentSocial.Types.valid_relationship_modes?(modes),
          do: [],
          else: [relationship_modes: "contains unsupported modes"]
      end)
      |> validate_number(:daily_post_limit,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> validate_number(:daily_message_limit,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 1_000
      )
      |> validate_change(:require_intro_approval, &consent_floor/2)
      |> validate_change(:require_contact_approval, &consent_floor/2)
      |> validate_change(:confirmation_requirements, &bounded_map/2)
      |> validate_change(:disclosure_rules, &bounded_map/2)
      |> unique_constraint(:human_id)

    if policy.__meta__.state == :loaded, do: optimistic_lock(changeset, :version), else: changeset
  end

  defp consent_floor(_field, true), do: []
  defp consent_floor(field, _), do: [{field, "cannot disable direct human consent"}]

  defp bounded_map(_field, value) when is_map(value) and map_size(value) <= 50, do: []
  defp bounded_map(field, _), do: [{field, "must contain at most 50 entries"}]
end
