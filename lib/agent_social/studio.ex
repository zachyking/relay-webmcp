defmodule AgentSocial.Studio do
  @moduledoc "Durable, capability-authenticated human review rooms for agent-authored drafts."

  import Ecto.Query

  alias AgentSocial.Identity.{AgentBinding, Human}
  alias AgentSocial.Studio.ReviewSession
  alias AgentSocial.{Operations, Repo, Social, Types}

  @review_decisions ~w(keep cut rewrite)
  @default_lifetime_seconds 7 * 24 * 60 * 60

  def session_lifetime_seconds do
    Application.get_env(
      :agent_social,
      :studio_review_session_max_age,
      @default_lifetime_seconds
    )
  end

  def create(%AgentBinding{} = binding, attrs, idempotency_key) do
    with {:ok, draft} <- normalize_draft(attrs) do
      token = review_token()
      now = DateTime.utc_now()

      result =
        Repo.transaction(fn ->
          session =
            %ReviewSession{human_id: binding.human_id, agent_binding_id: binding.id}
            |> ReviewSession.changeset(%{
              token_digest: digest(token),
              draft: draft,
              draft_version: 1,
              review: default_review(1),
              status: "review",
              expires_at: DateTime.add(now, session_lifetime_seconds(), :second),
              last_agent_action_at: now
            })
            |> Repo.insert!()

          record_agent_audit!(
            binding,
            "studio.review_created",
            session,
            idempotency_key,
            %{draft_version: 1}
          )

          session
        end)

      case result do
        {:ok, session} -> {:ok, session, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def get_by_token(token) when is_binary(token) do
    with true <- valid_token_format?(token),
         %ReviewSession{} = session <-
           Repo.one(
             from session in ReviewSession,
               join: human in Human,
               on: human.id == session.human_id,
               where: session.token_digest == ^digest(token),
               where: human.status == "active",
               preload: [:published_content]
           ),
         :ok <- ensure_available(session) do
      {:ok, session}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      error -> error
    end
  end

  def get_for_agent(%AgentBinding{} = binding, session_id) do
    case Repo.one(
           from session in ReviewSession,
             where: session.id == ^session_id and session.human_id == ^binding.human_id,
             preload: [:published_content]
         ) do
      %ReviewSession{} = session ->
        with :ok <- ensure_available(session), do: {:ok, session}

      nil ->
        {:error, :not_found}
    end
  end

  def revise(%AgentBinding{} = binding, session_id, based_on_version, attrs, idempotency_key) do
    with {:ok, draft} <- normalize_draft(attrs) do
      Repo.transaction(fn ->
        session = lock_for_agent!(binding, session_id)
        ensure_editable!(session)

        if session.draft_version != based_on_version,
          do: Repo.rollback(:stale_draft_version)

        unless Map.get(session.review, "ready", false),
          do: Repo.rollback(:review_not_ready)

        now = DateTime.utc_now()
        version = session.draft_version + 1

        updated =
          session
          |> Ecto.Changeset.change(%{
            agent_binding_id: binding.id,
            draft: draft,
            draft_version: version,
            review: default_review(version),
            expires_at: DateTime.add(now, session_lifetime_seconds(), :second),
            last_agent_action_at: now
          })
          |> Repo.update!()

        record_agent_audit!(
          binding,
          "studio.draft_revised",
          updated,
          idempotency_key,
          %{draft_version: version, based_on_version: based_on_version}
        )

        Repo.preload(updated, :published_content)
      end)
    end
  end

  def update_review(token, draft_version, attrs) do
    Repo.transaction(fn ->
      session = lock_by_token!(token)
      ensure_editable!(session)

      if session.draft_version != draft_version,
        do: Repo.rollback(:stale_draft_version)

      paragraph_count = session.draft |> Map.get("body", "") |> paragraphs() |> length()

      case normalize_review(attrs, draft_version, paragraph_count) do
        {:ok, review} ->
          updated =
            session
            |> Ecto.Changeset.change(%{
              review: Map.put(review, "ready", false),
              last_human_action_at: DateTime.utc_now()
            })
            |> Repo.update!()

          record_human_audit!(updated, "studio.review_updated", %{
            draft_version: draft_version,
            feedback_count: map_size(review["paragraph_feedback"])
          })

          Repo.preload(updated, :published_content)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def mark_review_ready(token, draft_version) do
    Repo.transaction(fn ->
      session = lock_by_token!(token)
      ensure_editable!(session)

      if session.draft_version != draft_version,
        do: Repo.rollback(:stale_draft_version)

      unless review_has_feedback?(session.review),
        do: Repo.rollback(:review_feedback_required)

      review = Map.put(session.review, "ready", true)

      updated =
        session
        |> Ecto.Changeset.change(review: review, last_human_action_at: DateTime.utc_now())
        |> Repo.update!()

      record_human_audit!(updated, "studio.review_ready", %{draft_version: draft_version})
      Repo.preload(updated, :published_content)
    end)
  end

  def publish_by_token(token, idempotency_key) do
    publish(fn -> lock_by_token!(token) end, nil, idempotency_key)
  end

  def publish_by_agent(%AgentBinding{} = binding, session_id, idempotency_key) do
    publish(fn -> lock_for_agent!(binding, session_id) end, binding, idempotency_key)
  end

  def serialize(%ReviewSession{} = session) do
    published =
      if session.published_content_id do
        %{
          id: session.published_content_id,
          url: "/posts/#{session.published_content_id}"
        }
      end

    %{
      id: session.id,
      draft: session.draft,
      draft_version: session.draft_version,
      review: session.review,
      status: session.status,
      published: published,
      expires_at: session.expires_at,
      updated_at: session.updated_at
    }
  end

  defp publish(lock_session, authenticated_binding, idempotency_key) do
    Repo.transaction(fn ->
      session = lock_session.()
      ensure_available!(session)

      if session.published_content_id do
        Repo.preload(session, :published_content)
      else
        binding = authenticated_binding || active_binding!(session)
        ensure_same_human!(binding, session)

        case Social.publish(binding, post_attrs(session.draft), idempotency_key) do
          {:ok, content} ->
            updated =
              session
              |> Ecto.Changeset.change(%{
                agent_binding_id: binding.id,
                published_content_id: content.id,
                status: "published",
                last_human_action_at: DateTime.utc_now()
              })
              |> Repo.update!()

            record_agent_audit!(
              binding,
              "studio.draft_published",
              updated,
              idempotency_key,
              %{draft_version: updated.draft_version, actor: publish_actor(authenticated_binding)}
            )

            Repo.preload(updated, :published_content)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end
    end)
  end

  defp normalize_draft(attrs) when is_map(attrs) do
    summary = text(attrs, "summary")
    body = text(attrs, "body")
    agent_note = text(attrs, "agent_note")
    modes = string_list(attrs, "relationship_modes") |> Enum.uniq()
    topics = string_list(attrs, "topic_ids") |> Enum.uniq()

    cond do
      summary == "" or String.length(summary) > 240 ->
        {:error, :invalid_draft}

      body == "" or byte_size(body) > 32_768 ->
        {:error, :invalid_draft}

      String.length(agent_note) > 500 ->
        {:error, :invalid_draft}

      modes == [] or not Types.valid_relationship_modes?(modes) ->
        {:error, :invalid_draft}

      length(topics) > 12 or Enum.any?(topics, &(String.length(&1) > 80)) ->
        {:error, :invalid_draft}

      true ->
        {:ok,
         %{
           "summary" => summary,
           "body" => body,
           "relationship_modes" => modes,
           "topic_ids" => topics,
           "agent_note" => agent_note
         }}
    end
  end

  defp normalize_draft(_attrs), do: {:error, :invalid_draft}

  defp normalize_review(attrs, draft_version, paragraph_count) when is_map(attrs) do
    overall_note = text(attrs, "overall_note")
    feedback = Map.get(attrs, "paragraph_feedback", %{})

    with true <- String.length(overall_note) <= 2_000,
         {:ok, normalized_feedback} <- normalize_feedback(feedback, paragraph_count) do
      {:ok,
       %{
         "draft_version" => draft_version,
         "overall_note" => overall_note,
         "paragraph_feedback" => normalized_feedback,
         "ready" => false
       }}
    else
      _ -> {:error, :invalid_review}
    end
  end

  defp normalize_review(_attrs, _draft_version, _paragraph_count),
    do: {:error, :invalid_review}

  defp normalize_feedback(feedback, paragraph_count) when is_map(feedback) do
    Enum.reduce_while(feedback, {:ok, %{}}, fn {raw_index, value}, {:ok, acc} ->
      with {index, ""} <- Integer.parse(to_string(raw_index)),
           true <- index >= 0 and index < paragraph_count,
           true <- is_map(value),
           decision <- text(value, "decision"),
           true <- decision == "" or decision in @review_decisions,
           comment <- text(value, "comment"),
           true <- String.length(comment) <= 1_000 do
        if decision == "" and comment == "" do
          {:cont, {:ok, acc}}
        else
          {:cont,
           {:ok,
            Map.put(acc, Integer.to_string(index), %{
              "decision" => decision,
              "comment" => comment
            })}}
        end
      else
        _ -> {:halt, {:error, :invalid_review}}
      end
    end)
  end

  defp normalize_feedback(_feedback, _paragraph_count), do: {:error, :invalid_review}

  defp default_review(version) do
    %{
      "draft_version" => version,
      "overall_note" => "",
      "paragraph_feedback" => %{},
      "ready" => false
    }
  end

  defp review_has_feedback?(review) do
    String.trim(Map.get(review, "overall_note", "")) != "" or
      map_size(Map.get(review, "paragraph_feedback", %{})) > 0
  end

  defp post_attrs(draft) do
    %{
      "kind" => "post",
      "relationship_modes" => draft["relationship_modes"],
      "topic_ids" => draft["topic_ids"],
      "visibility" => "public",
      "language" => "en",
      "format" => "text/plain",
      "encoding" => "identity",
      "rankable_metadata" => %{
        "summary" => draft["summary"],
        "collaboration_surface" => "shared_review_room"
      },
      "opaque_payload" => draft["body"]
    }
  end

  defp lock_by_token!(token) do
    unless valid_token_format?(token), do: Repo.rollback(:not_found)

    Repo.one(
      from session in ReviewSession,
        join: human in Human,
        on: human.id == session.human_id,
        where: session.token_digest == ^digest(token),
        where: human.status == "active",
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp lock_for_agent!(binding, session_id) do
    Repo.one(
      from session in ReviewSession,
        where: session.id == ^session_id and session.human_id == ^binding.human_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp active_binding!(session) do
    case Repo.one(
           from binding in AgentBinding,
             join: human in Human,
             on: human.id == binding.human_id,
             where:
               binding.id == ^session.agent_binding_id and binding.active == true and
                 human.status == "active"
         ) do
      %AgentBinding{} = binding -> binding
      nil -> Repo.rollback(:agent_disconnected)
    end
  end

  defp ensure_same_human!(binding, session) do
    if binding.human_id == session.human_id,
      do: :ok,
      else: Repo.rollback(:not_permitted)
  end

  defp ensure_available(%ReviewSession{} = session) do
    if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :expired}
  end

  defp ensure_available!(session) do
    case ensure_available(session) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_editable!(session) do
    ensure_available!(session)
    if session.status == "review", do: :ok, else: Repo.rollback(:already_published)
  end

  defp record_agent_audit!(binding, event, session, key, result_state) do
    binding
    |> Operations.agent_audit_attrs(event, "studio_review_session", session.id, key, result_state)
    |> Operations.audit_changeset()
    |> Repo.insert!()
  end

  defp record_human_audit!(session, event, result_state) do
    binding = Repo.get!(AgentBinding, session.agent_binding_id)

    attrs =
      Operations.agent_audit_attrs(
        binding,
        event,
        "studio_review_session",
        session.id,
        nil,
        result_state
      )
      |> Map.put(:metadata, %{actor: "human_review_link"})

    attrs |> Operations.audit_changeset() |> Repo.insert!()
  end

  defp publish_actor(nil), do: "human_review_link"
  defp publish_actor(%AgentBinding{}), do: "agent_tool"

  defp paragraphs(body) do
    String.split(body, ~r/\n\s*\n|\n/u, trim: true)
  end

  defp text(map, key) do
    value =
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, known_atom(key), "")
      end

    case value do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp known_atom("summary"), do: :summary
  defp known_atom("body"), do: :body
  defp known_atom("agent_note"), do: :agent_note
  defp known_atom("relationship_modes"), do: :relationship_modes
  defp known_atom("topic_ids"), do: :topic_ids
  defp known_atom("overall_note"), do: :overall_note
  defp known_atom("decision"), do: :decision
  defp known_atom("comment"), do: :comment

  defp string_list(map, key) do
    values =
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, known_atom(key), [])
      end

    case values do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp review_token do
    "rvw_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  defp valid_token_format?("rvw_" <> encoded), do: byte_size(encoded) in 42..44
  defp valid_token_format?(_token), do: false

  defp digest(value), do: :crypto.hash(:sha256, value)
end
