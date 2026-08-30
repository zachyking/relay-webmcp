defmodule AgentSocial.Safety.Report do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "reports" do
    field :reporter_human_id, Ecto.UUID
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :category, :string
    field :details, :map, default: %{}
    field :status, :string, default: "open"
    timestamps()
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:reporter_human_id, :subject_type, :subject_id, :category, :details, :status])
    |> validate_required([:reporter_human_id, :subject_type, :subject_id, :category])
    |> validate_inclusion(:subject_type, ~w(human content community message))
    |> validate_inclusion(
      :category,
      ~w(spam harassment phishing malware credential_abuse illegal_content privacy account_compromise other)
    )
    |> validate_inclusion(:status, ~w(open reviewing actioned dismissed))
    |> validate_change(:details, fn :details, details ->
      cond do
        not is_map(details) -> [details: "must be an object"]
        map_size(details) > 30 -> [details: "has too many fields"]
        byte_size(Jason.encode!(details)) > 8_192 -> [details: "exceeds 8192 bytes"]
        true -> []
      end
    end)
  end
end
