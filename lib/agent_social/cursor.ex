defmodule AgentSocial.Cursor do
  @moduledoc false

  def encode(%{inserted_at: inserted_at, id: id}) do
    [DateTime.to_iso8601(inserted_at), id]
    |> Enum.join("|")
    |> Base.url_encode64(padding: false)
  end

  def decode(nil), do: {:ok, nil}

  def decode(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         [timestamp, id] <- String.split(decoded, "|", parts: 2),
         {:ok, datetime, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {datetime, uuid}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_), do: {:error, :invalid_cursor}
end
