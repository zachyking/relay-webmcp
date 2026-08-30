defmodule AgentSocial.RateLimiter do
  @moduledoc "Valkey-backed fixed-window limits with a local development fallback."

  use GenServer

  @table :agent_social_rate_limits
  @script """
  local current = redis.call('INCR', KEYS[1])
  if current == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
  return current
  """

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def check(key, limit, window_seconds)
      when is_binary(key) and is_integer(limit) and is_integer(window_seconds) do
    count =
      if Process.whereis(AgentSocial.Redis) do
        redis_count(key, window_seconds)
      else
        local_count(key, window_seconds)
      end

    case count do
      {:ok, value} when value <= limit -> :ok
      {:ok, _value} -> {:error, :rate_limited, window_seconds}
      {:error, _reason} -> local_decision(key, limit, window_seconds)
    end
  end

  @impl GenServer
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{table: table}}
  end

  defp redis_count(key, window_seconds) do
    bucket = div(System.system_time(:second), window_seconds)

    Redix.command(AgentSocial.Redis, [
      "EVAL",
      @script,
      "1",
      "relay:rate:#{key}:#{bucket}",
      Integer.to_string(window_seconds + 1)
    ])
  end

  defp local_decision(key, limit, window_seconds) do
    case local_count(key, window_seconds) do
      {:ok, value} when value <= limit -> :ok
      {:ok, _value} -> {:error, :rate_limited, window_seconds}
    end
  end

  defp local_count(key, window_seconds) do
    bucket = div(System.system_time(:second), window_seconds)
    count = :ets.update_counter(@table, {key, bucket}, {2, 1}, {{key, bucket}, 0})

    if rem(count, 100) == 0 do
      previous = bucket - 2

      :ets.select_delete(@table, [
        {{{key, :"$1"}, :"$2"}, [{:<, :"$1", previous}], [true]}
      ])
    end

    {:ok, count}
  end
end
