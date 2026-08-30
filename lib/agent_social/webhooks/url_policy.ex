defmodule AgentSocial.Webhooks.URLPolicy do
  @moduledoc false

  def validate(url) when is_binary(url) do
    uri = URI.parse(url)

    with true <- uri.scheme == "https" or allow_http_local?(),
         true <- uri.scheme in ["https", "http"],
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         addresses <- resolve(host),
         true <- addresses != [] and Enum.all?(addresses, &(not private?(&1))) do
      :ok
    else
      _ -> {:error, :unsafe_webhook_url}
    end
  end

  def validate(_), do: {:error, :unsafe_webhook_url}

  defp resolve(host) do
    for family <- [:inet, :inet6],
        {:ok, addresses} = resolve_family(host, family),
        address <- addresses,
        do: address
  end

  defp resolve_family(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, addresses} -> {:ok, addresses}
      {:error, _reason} -> {:ok, []}
    end
  end

  defp allow_http_local?, do: Application.get_env(:agent_social, :allow_http_webhooks, false)

  defp private?({10, _, _, _}), do: true
  defp private?({127, _, _, _}), do: true
  defp private?({169, 254, _, _}), do: true
  defp private?({172, second, _, _}) when second in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?({0, _, _, _}), do: true
  defp private?({224, _, _, _}), do: true
  defp private?({first, _, _, _}) when first >= 240, do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  defp private?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: true
  defp private?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: true
  defp private?(_), do: false
end
