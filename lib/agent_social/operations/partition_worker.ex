defmodule AgentSocial.Operations.PartitionWorker do
  @moduledoc "Creates future monthly partitions for high-volume append-only tables."

  use Oban.Worker, queue: :lifecycle, max_attempts: 10, unique: [period: 86_400]

  alias AgentSocial.Repo

  @tables ~w(messages inbox_events audit_events)

  @impl Oban.Worker
  def perform(_job) do
    first = Date.beginning_of_month(Date.utc_today())

    for table <- @tables, offset <- 0..6 do
      from = month_offset(first, offset)
      until = month_offset(first, offset + 1)
      suffix = Calendar.strftime(from, "%Y_%m")

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS #{table}_#{suffix} PARTITION OF #{table}
      FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(until)}')
      """)
    end

    :ok
  end

  defp month_offset(%Date{year: year, month: month}, offset) do
    absolute_month = year * 12 + month - 1 + offset
    Date.new!(div(absolute_month, 12), rem(absolute_month, 12) + 1, 1)
  end
end
