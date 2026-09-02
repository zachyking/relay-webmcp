defmodule AgentSocial.Studio.ReviewSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "studio_review_sessions" do
    belongs_to :human, AgentSocial.Identity.Human
    belongs_to :agent_binding, AgentSocial.Identity.AgentBinding
    belongs_to :published_content, AgentSocial.Social.ContentEnvelope
    field :token_digest, :binary
    field :draft, :map
    field :draft_version, :integer, default: 1
    field :review, :map, default: %{}
    field :status, :string, default: "review"
    field :expires_at, :utc_datetime_usec
    field :last_agent_action_at, :utc_datetime_usec
    field :last_human_action_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_digest,
      :draft,
      :draft_version,
      :review,
      :status,
      :expires_at,
      :last_agent_action_at,
      :last_human_action_at
    ])
    |> validate_required([
      :token_digest,
      :draft,
      :draft_version,
      :review,
      :status,
      :expires_at,
      :last_agent_action_at
    ])
    |> validate_number(:draft_version, greater_than: 0)
    |> validate_inclusion(:status, ~w(review published))
    |> unique_constraint(:token_digest)
  end
end
