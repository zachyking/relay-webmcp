defmodule AgentSocial.Social do
  @moduledoc "Communities, content envelopes, discovery, and reactions."

  import Ecto.Query
  alias Ecto.Multi
  alias AgentSocial.{Cursor, Operations, Repo}
  alias AgentSocial.Identity.AgentBinding

  alias AgentSocial.Social.{
    Community,
    CommunityMembership,
    CommunityRule,
    ContentEnvelope,
    ModerationAction,
    Reaction
  }

  def create_community(%AgentBinding{} = binding, attrs, idempotency_key \\ nil) do
    Multi.new()
    |> Multi.insert(:community, fn _ ->
      %Community{creator_human_id: binding.human_id}
      |> Community.changeset(attrs)
    end)
    |> Multi.insert(:membership, fn %{community: community} ->
      %CommunityMembership{community_id: community.id, human_id: binding.human_id}
      |> CommunityMembership.changeset(%{role: "owner", status: "active"})
    end)
    |> Multi.insert(:rule, fn %{community: community} ->
      %CommunityRule{community_id: community.id, created_by_human_id: binding.human_id}
      |> CommunityRule.changeset(%{version: 1, rules: community.rules})
    end)
    |> Multi.insert(:audit, fn %{community: community} ->
      Operations.audit_changeset(
        audit_attrs(binding, "community.created", "community", community.id, idempotency_key)
      )
    end)
    |> Repo.transaction()
    |> unwrap(:community)
  end

  def set_community_rules(%AgentBinding{} = binding, community_id, attrs, idempotency_key \\ nil) do
    with %CommunityMembership{role: "owner", status: "active"} <-
           Repo.get_by(CommunityMembership,
             community_id: community_id,
             human_id: binding.human_id
           ) do
      Multi.new()
      |> Multi.run(:community, fn repo, _ ->
        case repo.one(
               from community in Community,
                 where: community.id == ^community_id,
                 lock: "FOR UPDATE"
             ) do
          nil -> {:error, :not_found}
          community -> {:ok, community}
        end
      end)
      |> Multi.update(:updated_community, fn %{community: community} ->
        Community.changeset(community, %{
          "rules" => attrs["rules"],
          "relationship_modes" => attrs["relationship_modes"] || community.relationship_modes
        })
      end)
      |> Multi.run(:version, fn repo, _ ->
        version =
          repo.one(
            from rule in CommunityRule,
              where: rule.community_id == ^community_id,
              select: max(rule.version)
          ) || 0

        {:ok, version + 1}
      end)
      |> Multi.insert(:rule, fn %{version: version} ->
        %CommunityRule{community_id: community_id, created_by_human_id: binding.human_id}
        |> CommunityRule.changeset(%{version: version, rules: attrs["rules"]})
      end)
      |> Multi.insert(:audit, fn %{rule: rule} ->
        binding
        |> Operations.agent_audit_attrs(
          "community.rules_set",
          "community_rule",
          rule.id,
          idempotency_key,
          %{community_id: community_id, version: rule.version}
        )
        |> Operations.audit_changeset()
      end)
      |> Repo.transaction()
      |> unwrap(:rule)
    else
      nil -> {:error, :not_permitted}
      %CommunityMembership{} -> {:error, :not_permitted}
    end
  end

  def join_community(%AgentBinding{} = binding, community_id, idempotency_key \\ nil) do
    with %Community{status: "active"} = community <- Repo.get(Community, community_id),
         true <- community.admission == "open" do
      %CommunityMembership{community_id: community.id, human_id: binding.human_id}
      |> CommunityMembership.changeset(%{role: "member", status: "active"})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:community_id, :human_id])
      |> case do
        {:ok, membership} ->
          _ =
            record_audit(binding, "community.joined", "community", community.id, idempotency_key)

          {:ok, membership}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :approval_required}
    end
  end

  def moderate_community(%AgentBinding{} = binding, community_id, attrs, idempotency_key \\ nil) do
    with %Community{} = community <- Repo.get(Community, community_id),
         %CommunityMembership{role: role, status: "active"} <-
           Repo.get_by(CommunityMembership,
             community_id: community.id,
             human_id: binding.human_id
           ),
         true <- role in ["owner", "moderator"],
         {:ok, subject_id} <- Ecto.UUID.cast(attrs["subject_id"]),
         :ok <- authorize_moderation(role, attrs["action"]),
         :ok <- validate_moderation_subject(community.id, attrs["subject_type"], subject_id) do
      Multi.new()
      |> Multi.run(:effect, fn repo, _ ->
        apply_moderation(repo, community.id, attrs["subject_type"], subject_id, attrs["action"])
      end)
      |> Multi.insert(:action, fn _ ->
        ModerationAction.changeset(%ModerationAction{}, %{
          community_id: community.id,
          moderator_human_id: binding.human_id,
          subject_type: attrs["subject_type"],
          subject_id: subject_id,
          action: attrs["action"],
          reason: Map.get(attrs, "reason", %{})
        })
      end)
      |> Multi.insert(:audit, fn %{action: action} ->
        Operations.audit_changeset(
          audit_attrs(
            binding,
            "community.moderated",
            "moderation_action",
            action.id,
            idempotency_key
          )
          |> Map.put(:metadata, %{
            community_id: community.id,
            subject_type: action.subject_type,
            subject_id: action.subject_id,
            action: action.action
          })
        )
      end)
      |> Repo.transaction()
      |> unwrap(:action)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_permitted}
      :error -> {:error, :invalid_subject_id}
      %CommunityMembership{} -> {:error, :not_permitted}
      error -> error
    end
  end

  def publish(%AgentBinding{} = binding, attrs, idempotency_key \\ nil) do
    attrs = normalize_payload(attrs)

    with :ok <- enforce_community_membership(binding.human_id, attrs["community_id"]),
         :ok <- enforce_post_limit(binding.human_id) do
      Multi.new()
      |> Multi.insert(:content, fn _ ->
        %ContentEnvelope{author_human_id: binding.human_id, agent_binding_id: binding.id}
        |> ContentEnvelope.changeset(
          Map.put_new(attrs, "provenance", %{
            "client" => binding.client_name,
            "key_version" => binding.key_version
          })
        )
      end)
      |> Multi.insert(:audit, fn %{content: content} ->
        Operations.audit_changeset(
          audit_attrs(binding, "content.published", "content", content.id, idempotency_key)
        )
      end)
      |> Multi.insert(:outbox, fn %{content: content} ->
        Operations.outbox_changeset(%{
          topic: "content",
          event_type: "content.published",
          resource_type: "content",
          resource_id: content.id
        })
      end)
      |> Repo.transaction()
      |> unwrap(:content)
      |> enqueue_embedding()
    end
  end

  def reply(binding, parent_id, attrs, idempotency_key \\ nil) do
    attrs = attrs |> Map.put("parent_id", parent_id) |> Map.put("kind", "reply")
    publish(binding, attrs, idempotency_key)
  end

  def set_reaction(%AgentBinding{} = binding, content_id, kind) do
    with {:ok, _content} <- get_item(content_id, binding.human_id) do
      %Reaction{content_id: content_id, human_id: binding.human_id}
      |> Reaction.changeset(%{kind: kind})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:content_id, :human_id, :kind])
    end
  end

  def get_item(id, viewer_id \\ nil) do
    query =
      visible_query(viewer_id)
      |> where([content], content.id == ^id)
      |> preload([:author, :community])

    case Repo.one(query),
      do: (
        nil -> {:error, :not_found}
        content -> {:ok, content}
      )
  end

  @doc "Returns public root envelopes with the number of public replies in each thread."
  def list_public_conversations(opts \\ []) do
    opts
    |> Keyword.put(:per_page, Keyword.get(opts, :limit, 24))
    |> browse_public_conversations()
    |> Map.fetch!(:entries)
  end

  @doc "Searches, orders, and paginates public root conversations for the human reader."
  def browse_public_conversations(opts \\ []) do
    query_text =
      opts
      |> Keyword.get(:query, "")
      |> to_string()
      |> String.trim()
      |> String.slice(0, 200)

    sort = normalize_public_sort(Keyword.get(opts, :sort, "latest"))
    page = positive_integer(Keyword.get(opts, :page, 1), 1)
    per_page = opts |> Keyword.get(:per_page, 24) |> positive_integer(24) |> min(48)

    roots =
      visible_query(nil)
      |> where([content], is_nil(content.parent_id))
      |> maybe_public_search(query_text)

    total_count = Repo.aggregate(roots, :count, :id)
    total_pages = max(Integer.ceil_div(total_count, per_page), 1)
    page = min(page, total_pages)

    reply_counts =
      visible_query(nil)
      |> where([content], not is_nil(content.parent_id))
      |> group_by([content], content.parent_id)
      |> select([content], %{parent_id: content.parent_id, reply_count: count(content.id)})

    entries =
      roots
      |> join(:left, [content], replies in subquery(reply_counts),
        on: replies.parent_id == content.id
      )
      |> order_public_conversations(sort)
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> preload([content, _replies], [:author, :community])
      |> select([content, replies], %{
        post: content,
        reply_count: fragment("COALESCE(?, 0)", replies.reply_count)
      })
      |> Repo.all()

    %{
      entries: entries,
      query: query_text,
      sort: sort,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  @doc "Loads a public root envelope and its public replies for the human reader."
  def get_public_conversation(id) do
    with {:ok, requested_item} <- get_item(id, nil),
         {:ok, post} <- public_root(requested_item) do
      replies =
        visible_query(nil)
        |> where([content], content.parent_id == ^post.id)
        |> order_by([content], asc: content.inserted_at, asc: content.id)
        |> preload([:author, :community])
        |> Repo.all()

      {:ok, %{post: post, replies: replies, requested_item: requested_item}}
    end
  end

  def browse_feed(viewer_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 30) |> min(100) |> max(1)

    with {:ok, cursor} <- Cursor.decode(Keyword.get(opts, :cursor)) do
      query =
        visible_query(viewer_id)
        |> maybe_before(cursor)
        |> order_by([content], desc: content.inserted_at, desc: content.id)
        |> limit(^(limit * 4))
        |> preload([:author, :community])

      contents = Repo.all(query)
      ranked = rank(contents, viewer_id, limit)
      next_cursor = ranked |> List.last() |> then(&if(&1, do: Cursor.encode(&1), else: nil))
      {:ok, ranked, next_cursor}
    end
  end

  def search(viewer_id, query_text, opts \\ []) when is_binary(query_text) do
    limit = opts |> Keyword.get(:limit, 30) |> min(100) |> max(1)

    visible_query(viewer_id)
    |> where(
      [content],
      fragment("? @@ websearch_to_tsquery('simple', ?)", content.search_document, ^query_text)
    )
    |> order_by([content],
      desc:
        fragment(
          "ts_rank_cd(?, websearch_to_tsquery('simple', ?))",
          content.search_document,
          ^query_text
        ),
      desc: content.inserted_at
    )
    |> limit(^limit)
    |> preload([:author, :community])
    |> Repo.all()
  end

  defp maybe_public_search(query, ""), do: query

  defp maybe_public_search(query, query_text) do
    where(
      query,
      [content],
      fragment("? @@ websearch_to_tsquery('simple', ?)", content.search_document, ^query_text)
    )
  end

  defp order_public_conversations(query, "oldest") do
    order_by(query, [content, _replies], asc: content.inserted_at, asc: content.id)
  end

  defp order_public_conversations(query, "discussed") do
    order_by(query, [content, replies],
      desc: fragment("COALESCE(?, 0)", replies.reply_count),
      desc: content.inserted_at,
      desc: content.id
    )
  end

  defp order_public_conversations(query, _latest) do
    order_by(query, [content, _replies], desc: content.inserted_at, desc: content.id)
  end

  defp normalize_public_sort(sort) when sort in ~w(latest oldest discussed), do: sort
  defp normalize_public_sort(_sort), do: "latest"

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp visible_query(nil) do
    from content in ContentEnvelope,
      where: content.visibility == "public" and is_nil(content.deleted_at),
      where: is_nil(content.expires_at) or content.expires_at > ^DateTime.utc_now()
  end

  defp visible_query(viewer_id) do
    blocked_ids =
      from block in "blocks",
        where:
          block.blocker_human_id == type(^viewer_id, Ecto.UUID) or
            block.blocked_human_id == type(^viewer_id, Ecto.UUID),
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            block.blocker_human_id,
            type(^viewer_id, Ecto.UUID),
            block.blocked_human_id,
            block.blocker_human_id
          )

    community_ids =
      from membership in CommunityMembership,
        where: membership.human_id == ^viewer_id and membership.status == "active",
        select: membership.community_id

    connection_ids =
      from connection in "connections",
        where:
          field(connection, :status) == "active" and
            (field(connection, :human_a_id) == type(^viewer_id, Ecto.UUID) or
               field(connection, :human_b_id) == type(^viewer_id, Ecto.UUID)),
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            field(connection, :human_a_id),
            type(^viewer_id, Ecto.UUID),
            field(connection, :human_b_id),
            field(connection, :human_a_id)
          )

    relationship_modes = AgentSocial.Identity.get_policy(viewer_id).relationship_modes

    from content in ContentEnvelope,
      where: is_nil(content.deleted_at),
      where: is_nil(content.expires_at) or content.expires_at > ^DateTime.utc_now(),
      where: content.author_human_id not in subquery(blocked_ids),
      where:
        content.author_human_id == ^viewer_id or
          fragment("? && ?", content.relationship_modes, ^relationship_modes),
      where:
        content.visibility in ["public", "network"] or content.author_human_id == ^viewer_id or
          (content.visibility == "community" and content.community_id in subquery(community_ids)) or
          (content.visibility == "connection" and
             content.author_human_id in subquery(connection_ids))
  end

  defp public_root(%ContentEnvelope{parent_id: nil} = content), do: {:ok, content}

  defp public_root(%ContentEnvelope{parent_id: parent_id}) do
    with {:ok, parent} <- get_item(parent_id, nil), do: public_root(parent)
  end

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, {timestamp, id}) do
    from content in query,
      where:
        content.inserted_at < ^timestamp or
          (content.inserted_at == ^timestamp and content.id < ^id)
  end

  defp rank(contents, viewer_id, limit) do
    preferences =
      if viewer_id do
        AgentSocial.Identity.get_policy(viewer_id).relationship_modes
      else
        []
      end

    now = DateTime.utc_now()
    configuration = AgentSocial.Governance.active_configuration()
    settings = configuration.configuration
    weights = settings["ranking"]
    exploration_percent = get_in(settings, ["exploration", "percent"]) || 15

    scored =
      Enum.map(contents, fn content ->
        overlap =
          MapSet.intersection(MapSet.new(preferences), MapSet.new(content.relationship_modes))
          |> MapSet.size()

        age_hours = max(DateTime.diff(now, content.inserted_at, :hour), 0)
        freshness = :math.exp(-age_hours / 72)
        reputation = Decimal.to_float(content.author.reputation) / 100

        compatibility = if preferences == [], do: 0.5, else: overlap / length(preferences)

        score =
          compatibility * weights["compatibility"] + freshness * weights["freshness"] +
            reputation * weights["reputation"] +
            exploration_score(content.id) * weights["exploration"]

        {score, content}
      end)
      |> Enum.sort_by(fn {score, content} -> {-score, content.id} end)

    exploration_count = min(round(limit * exploration_percent / 100), length(scored))
    primary_count = max(limit - exploration_count, 0)
    primary = Enum.take(scored, primary_count)
    primary_ids = MapSet.new(primary, fn {_score, content} -> content.id end)

    exploration =
      scored
      |> Enum.reject(fn {_score, content} -> MapSet.member?(primary_ids, content.id) end)
      |> Enum.sort_by(
        fn {_score, content} -> {exploration_score(content.id), content.id} end,
        :desc
      )
      |> Enum.take(exploration_count)

    (primary ++ exploration)
    |> Enum.map(fn {score, content} ->
      %{
        content
        | ranking_score: Float.round(score, 6),
          ranking_configuration_version: configuration.version
      }
    end)
  end

  defp exploration_score(id) do
    <<number::unsigned-integer-size(16), _::binary>> = :crypto.hash(:sha256, id)
    number / 65_535
  end

  defp normalize_payload(%{"opaque_payload" => payload} = attrs) when is_map(payload) do
    attrs
    |> Map.put("opaque_payload", Jason.encode!(payload))
    |> Map.put("format", "application/json")
  end

  defp normalize_payload(attrs), do: attrs

  defp enqueue_embedding({:ok, content} = result) do
    _ = AgentSocial.Discovery.EmbeddingWorker.enqueue(content)
    result
  end

  defp enqueue_embedding(error), do: error

  defp enforce_community_membership(_, nil), do: :ok

  defp enforce_community_membership(human_id, community_id) do
    if Repo.exists?(
         from m in CommunityMembership,
           where:
             m.community_id == ^community_id and m.human_id == ^human_id and m.status == "active"
       ) do
      :ok
    else
      {:error, :community_membership_required}
    end
  end

  defp enforce_post_limit(human_id) do
    policy = AgentSocial.Identity.get_policy(human_id)
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    count =
      Repo.aggregate(
        from(c in ContentEnvelope,
          where: c.author_human_id == ^human_id and c.inserted_at >= ^since
        ),
        :count
      )

    if count < policy.daily_post_limit, do: :ok, else: {:error, :daily_post_limit}
  end

  defp authorize_moderation("owner", action)
       when action in ~w(remove_content restore_content remove_member restore_member appoint_moderator),
       do: :ok

  defp authorize_moderation("moderator", action)
       when action in ~w(remove_content restore_content remove_member restore_member),
       do: :ok

  defp authorize_moderation(_, _), do: {:error, :not_permitted}

  defp validate_moderation_subject(community_id, "content", subject_id) do
    if Repo.exists?(
         from content in ContentEnvelope,
           where: content.id == ^subject_id and content.community_id == ^community_id
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp validate_moderation_subject(community_id, "human", subject_id) do
    if Repo.exists?(
         from membership in CommunityMembership,
           where: membership.human_id == ^subject_id and membership.community_id == ^community_id
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp validate_moderation_subject(_, _, _), do: {:error, :invalid_subject_type}

  defp apply_moderation(repo, community_id, "content", subject_id, action)
       when action in ["remove_content", "restore_content"] do
    deleted_at = if action == "remove_content", do: DateTime.utc_now(), else: nil

    {count, _} =
      repo.update_all(
        from(content in ContentEnvelope,
          where: content.id == ^subject_id and content.community_id == ^community_id
        ),
        set: [deleted_at: deleted_at]
      )

    if count == 1, do: {:ok, :updated}, else: {:error, :not_found}
  end

  defp apply_moderation(repo, community_id, "human", subject_id, action)
       when action in ["remove_member", "restore_member", "appoint_moderator"] do
    changes =
      case action do
        "remove_member" -> [status: "removed"]
        "restore_member" -> [status: "active"]
        "appoint_moderator" -> [role: "moderator", status: "active"]
      end

    query =
      from membership in CommunityMembership,
        where:
          membership.community_id == ^community_id and membership.human_id == ^subject_id and
            membership.role != "owner"

    case repo.update_all(query, set: changes) do
      {1, _} -> {:ok, :updated}
      _ -> {:error, :not_permitted}
    end
  end

  defp apply_moderation(_, _, _, _, _), do: {:error, :invalid_moderation_action}

  defp record_audit(binding, event, type, id, key) do
    audit_attrs(binding, event, type, id, key) |> Operations.audit_changeset() |> Repo.insert()
  end

  defp audit_attrs(binding, event, type, id, key) do
    Operations.agent_audit_attrs(binding, event, type, id, key)
  end

  defp unwrap({:ok, result}, key), do: {:ok, Map.fetch!(result, key)}
  defp unwrap({:error, step, reason, _}, _key), do: {:error, {step, reason}}
end
