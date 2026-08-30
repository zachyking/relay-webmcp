defmodule AgentSocial.Social.ContentEnvelope do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "content_envelopes" do
    belongs_to :author, AgentSocial.Identity.Human, foreign_key: :author_human_id
    belongs_to :agent_binding, AgentSocial.Identity.AgentBinding
    belongs_to :community, AgentSocial.Social.Community
    belongs_to :parent, __MODULE__
    field :kind, :string
    field :relationship_modes, {:array, :string}, default: []
    field :topic_ids, {:array, :string}, default: []
    field :visibility, :string, default: "public"
    field :language, :string, default: "en"
    field :format, :string, default: "text/plain"
    field :encoding, :string, default: "identity"
    field :schema_uri, :string
    field :rankable_metadata, :map, default: %{}
    field :opaque_payload, :string
    field :search_document, :string, load_in_query: false
    field :embedding, Pgvector.Ecto.Vector
    field :provenance, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    field :ranking_score, :float, virtual: true
    field :ranking_configuration_version, :integer, virtual: true
    timestamps()
  end

  def changeset(content, attrs) do
    content
    |> cast(attrs, [
      :community_id,
      :parent_id,
      :kind,
      :relationship_modes,
      :topic_ids,
      :visibility,
      :language,
      :format,
      :encoding,
      :schema_uri,
      :rankable_metadata,
      :opaque_payload,
      :provenance,
      :expires_at
    ])
    |> validate_required([
      :kind,
      :relationship_modes,
      :visibility,
      :language,
      :format,
      :encoding,
      :opaque_payload
    ])
    |> validate_inclusion(:kind, AgentSocial.Types.content_kinds())
    |> validate_inclusion(:visibility, AgentSocial.Types.visibilities())
    |> validate_inclusion(:format, ["text/plain", "application/json"])
    |> validate_inclusion(:encoding, ["identity", "base64url", "agent-defined"])
    |> validate_length(:language, min: 2, max: 35)
    |> validate_length(:schema_uri, max: 500)
    |> validate_custom_schema()
    |> validate_rankable_metadata()
    |> validate_change(:relationship_modes, fn :relationship_modes, modes ->
      if AgentSocial.Types.valid_relationship_modes?(modes),
        do: [],
        else: [relationship_modes: "contains unsupported modes"]
    end)
    |> validate_change(:opaque_payload, fn :opaque_payload, value ->
      if byte_size(value) <= 32_768, do: [], else: [opaque_payload: "exceeds 32768 bytes"]
    end)
    |> validate_json_payload()
  end

  defp validate_custom_schema(changeset) do
    if get_field(changeset, :kind) == "custom" and is_nil(get_field(changeset, :schema_uri)) do
      add_error(changeset, :schema_uri, "is required for custom content")
    else
      changeset
    end
  end

  defp validate_rankable_metadata(changeset) do
    validate_change(changeset, :rankable_metadata, fn :rankable_metadata, metadata ->
      cond do
        not is_map(metadata) ->
          [rankable_metadata: "must be an object"]

        map_size(metadata) > 50 ->
          [rankable_metadata: "has too many fields"]

        byte_size(Jason.encode!(metadata)) > 8_192 ->
          [rankable_metadata: "exceeds 8192 bytes"]

        true ->
          []
      end
    end)
  end

  defp validate_json_payload(changeset) do
    if get_field(changeset, :format) == "application/json" do
      validate_change(changeset, :opaque_payload, fn :opaque_payload, value ->
        case Jason.decode(value) do
          {:ok, _} -> []
          _ -> [opaque_payload: "must contain valid JSON"]
        end
      end)
    else
      changeset
    end
  end
end
