defmodule AgentSocial.Notifier.LogAdapter do
  @moduledoc false
  require Logger

  def deliver(%{template: template, to: recipient}) do
    Logger.notice("Development notification issued",
      template: template,
      recipient_hash: short_hash(recipient)
    )

    :ok
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false) |> binary_part(0, 12)
  end
end
