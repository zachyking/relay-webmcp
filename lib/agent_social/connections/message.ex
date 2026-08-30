defmodule AgentSocial.Connections.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "messages" do
    field :thread_id, Ecto.UUID
    field :sender_human_id, Ecto.UUID
    field :agent_binding_id, Ecto.UUID
    field :format, :string, default: "text/plain"
    field :encoding, :string, default: "identity"
    field :schema_uri, :string
    field :opaque_payload, :string
    field :metadata, :map, default: %{}
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:format, :encoding, :schema_uri, :opaque_payload, :metadata])
    |> validate_required([:format, :encoding, :opaque_payload])
    |> validate_inclusion(:format, ["text/plain", "application/json"])
    |> validate_inclusion(:encoding, ["identity", "base64url", "agent-defined"])
    |> validate_change(:opaque_payload, fn :opaque_payload, value ->
      if byte_size(value) <= 32_768, do: [], else: [opaque_payload: "exceeds 32768 bytes"]
    end)
  end
end
