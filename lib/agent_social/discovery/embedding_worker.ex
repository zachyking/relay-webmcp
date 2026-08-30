defmodule AgentSocial.Discovery.EmbeddingWorker do
  @moduledoc "Generates vectors from bounded rankable metadata only. Opaque payloads never enter this worker."

  use Oban.Worker,
    queue: :discovery,
    max_attempts: 8,
    unique: [period: :infinity, fields: [:args]]

  alias AgentSocial.Repo
  alias AgentSocial.Social.ContentEnvelope

  def enqueue(%ContentEnvelope{id: id}) do
    if enabled?() do
      %{content_id: id} |> new() |> Oban.insert()
    else
      {:ok, :disabled}
    end
  end

  def enabled? do
    config()[:endpoint] not in [nil, ""]
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"content_id" => content_id}}) do
    case Repo.get(ContentEnvelope, content_id) do
      nil ->
        {:discard, :content_not_found}

      %ContentEnvelope{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:discard, :content_deleted}

      %ContentEnvelope{} = content ->
        with {:ok, vector} <- embed(content.rankable_metadata),
             {:ok, _content} <-
               content
               |> Ecto.Changeset.change(embedding: vector)
               |> Repo.update() do
          :ok
        end
    end
  end

  def embed(metadata) when is_map(metadata) do
    settings = config()
    dimensions = settings[:dimensions] || 768

    headers =
      case settings[:api_key] do
        key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
        _ -> []
      end

    body = %{
      input: Jason.encode!(metadata),
      model: settings[:model],
      dimensions: dimensions
    }

    request_options = settings[:request_options] || []

    case Req.post(
           settings[:endpoint],
           [json: body, headers: headers, redirect: false, receive_timeout: 30_000] ++
             request_options
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        response |> extract_vector() |> validate_vector(dimensions)

      {:ok, %{status: status}} ->
        {:error, {:embedding_http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_vector(%{"data" => [%{"embedding" => vector} | _]}), do: vector
  defp extract_vector(%{"embedding" => vector}), do: vector
  defp extract_vector(_), do: nil

  defp validate_vector(vector, dimensions)
       when is_list(vector) and length(vector) == dimensions do
    if Enum.all?(vector, &is_number/1),
      do: {:ok, Pgvector.new(vector)},
      else: {:error, :invalid_embedding}
  end

  defp validate_vector(_, _), do: {:error, :invalid_embedding_dimensions}

  defp config, do: Application.get_env(:agent_social, :embeddings, [])
end
