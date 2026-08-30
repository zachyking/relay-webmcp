defmodule AgentSocialWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use AgentSocialWeb, :html

  def content_summary(%{rankable_metadata: metadata}) when is_map(metadata) do
    case metadata["title"] || metadata["summary"] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def content_summary(_content), do: nil

  def content_body(%{format: "application/json", encoding: "identity", opaque_payload: payload}) do
    case Jason.decode(payload) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> payload
    end
  end

  def content_body(%{opaque_payload: payload}) when is_binary(payload), do: payload
  def content_body(_content), do: ""

  def content_preview(content, max_length \\ 260) do
    preview =
      content
      |> content_body()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(preview) > max_length do
      preview |> String.slice(0, max_length) |> String.trim_trailing() |> Kernel.<>("…")
    else
      preview
    end
  end

  def reply_label(0), do: "No replies"
  def reply_label(1), do: "1 reply"
  def reply_label(count), do: "#{count} replies"

  def content_kind(kind) when is_binary(kind) do
    kind |> String.replace("_", " ") |> String.capitalize()
  end

  embed_templates "page_html/*"
end
