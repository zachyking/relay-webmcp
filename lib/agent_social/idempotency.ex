defmodule AgentSocial.Idempotency do
  @moduledoc "Claims mutation keys and replays completed responses for safe agent retries."

  import Ecto.Query
  alias AgentSocial.Operations.IdempotencyKey
  alias AgentSocial.Repo

  def claim(human_id, operation, key, request_body) do
    now = DateTime.utc_now()
    request_hash = request_hash(operation, request_body)

    Repo.delete_all(
      from record in IdempotencyKey,
        where:
          record.human_id == ^human_id and record.operation == ^operation and
            record.key == ^key and record.expires_at <= ^now
    )

    attrs = %{
      human_id: human_id,
      operation: operation,
      key: key,
      request_hash: request_hash,
      expires_at: DateTime.add(now, 24, :hour)
    }

    %IdempotencyKey{}
    |> IdempotencyKey.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Enum.any?(changeset.errors, fn
             {:human_id, {_message, metadata}} -> metadata[:constraint] == :unique
             _ -> false
           end) do
          replay_existing(human_id, operation, key, request_hash)
        else
          {:error, changeset}
        end
    end
  end

  def complete(id, status, body) when is_integer(status) and is_map(body) do
    id
    |> then(&Repo.get!(IdempotencyKey, &1))
    |> Ecto.Changeset.change(
      response_status: status,
      response_payload: Jason.encode!(body)
    )
    |> Repo.update()
    |> case do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def purge_expired do
    Repo.delete_all(
      from record in IdempotencyKey, where: record.expires_at <= ^DateTime.utc_now()
    )

    :ok
  end

  defp replay_existing(human_id, operation, key, request_hash) do
    record = Repo.get_by!(IdempotencyKey, human_id: human_id, operation: operation, key: key)

    cond do
      record.request_hash != request_hash ->
        {:error, :idempotency_payload_mismatch}

      is_integer(record.response_status) and is_binary(record.response_payload) ->
        {:replay, record.response_status, Jason.decode!(record.response_payload)}

      true ->
        {:error, :idempotency_in_progress}
    end
  end

  defp request_hash(operation, request_body) do
    canonical = canonicalize(request_body)
    :crypto.hash(:sha256, :erlang.term_to_binary({operation, canonical}))
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonicalize(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value
end
