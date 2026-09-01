defmodule AgentSocial.Identity do
  @moduledoc "Human identity, single-agent binding, profile, policy, and enrollment workflows."

  import Ecto.Query
  alias Ecto.Multi
  alias AgentSocial.Repo

  alias AgentSocial.Identity.{
    AgentBinding,
    EnrollmentChallenge,
    Human,
    Policy,
    ProfileClaim
  }

  alias AgentSocial.Operations
  alias AgentSocial.PlatformPolicies

  @default_scopes ~w(profile:read profile:write feed:read content:write community:write thread:write connection:write governance:write webhook:write)

  def start_enrollment(attrs) do
    with true <- Map.get(attrs, "adult_attested") == true,
         {:ok, email} <- fetch_string(attrs, "email"),
         {:ok, handle} <- fetch_string(attrs, "handle"),
         {:ok, client_name} <- fetch_string(attrs, "client_name"),
         :ok <- enrollment_identity_available(email, handle),
         {:ok, public_key} <- decode_sized(attrs["public_key"], 32) do
      otp = (:rand.uniform(900_000) + 99_999) |> Integer.to_string()
      nonce = :crypto.strong_rand_bytes(32)
      ttl = auth_config(:enrollment_otp_ttl_seconds, 600)
      policy_version = PlatformPolicies.version()
      expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

      challenge =
        %EnrollmentChallenge{email_hash: email_hash(email)}
        |> EnrollmentChallenge.changeset(%{
          handle: String.downcase(handle),
          email: normalize_email(email),
          public_key: public_key,
          nonce: nonce,
          otp_digest: digest(otp),
          client_name: client_name,
          terms_version: policy_version,
          guidelines_version: policy_version,
          expires_at: expires_at
        })

      case Repo.insert(challenge) do
        {:ok, stored} ->
          case AgentSocial.Notifier.enrollment_otp(email, otp, %{
                 policy_version: policy_version,
                 terms_url: public_url("/terms"),
                 guidelines_url: public_url("/community-guidelines"),
                 expires_at: DateTime.to_iso8601(expires_at)
               }) do
            :ok ->
              response = %{
                challenge_id: stored.id,
                nonce: Base.url_encode64(nonce, padding: false),
                signature_message: "base64url(nonce) + ':' + otp",
                expires_at: stored.expires_at
              }

              response =
                if reveal_otp?(), do: Map.put(response, :development_otp, otp), else: response

              {:ok, response}

            {:error, _reason} ->
              Repo.delete(stored)
              {:error, :notification_delivery_failed}
          end

        error ->
          error
      end
    else
      false -> {:error, :adult_attestation_required}
      error -> error
    end
  end

  def finish_enrollment(attrs) do
    with {:ok, challenge_id} <- Ecto.UUID.cast(attrs["challenge_id"]),
         %EnrollmentChallenge{} = challenge <- Repo.get(EnrollmentChallenge, challenge_id),
         :ok <- validate_challenge(challenge, attrs),
         {:ok, signature} <- decode_sized(attrs["signature"], 64) do
      message = Base.url_encode64(challenge.nonce, padding: false) <> ":" <> attrs["otp"]

      if :crypto.verify(:eddsa, :none, message, signature, [challenge.public_key, :ed25519]) do
        complete_enrollment(challenge, Map.get(attrs, "oidc_subject"))
      else
        {:error, :invalid_signature}
      end
    else
      nil -> {:error, :challenge_not_found}
      :error -> {:error, :invalid_challenge_id}
      error -> error
    end
  end

  def authenticate_token(token) when is_binary(token) do
    token_digest = digest(token)

    query =
      from binding in AgentBinding,
        join: human in assoc(binding, :human),
        where:
          binding.token_digest == ^token_digest and binding.active == true and
            human.status == "active",
        preload: [human: human]

    case Repo.one(query) do
      nil ->
        {:error, :unauthorized}

      binding ->
        _ =
          Repo.update_all(from(b in AgentBinding, where: b.id == ^binding.id),
            set: [last_seen_at: DateTime.utc_now()]
          )

        {:ok, binding}
    end
  end

  def get_profile(human_id, viewer_id \\ nil) do
    human = Repo.get!(Human, human_id)

    allowed =
      cond do
        viewer_id == human_id -> AgentSocial.Types.visibilities()
        is_nil(viewer_id) -> ["public"]
        connected?(human_id, viewer_id) -> ["public", "network", "connection"]
        true -> ["public", "network"]
      end

    claims =
      Repo.all(
        from c in ProfileClaim,
          where: c.human_id == ^human_id and c.visibility in ^allowed,
          order_by: c.key
      )

    %{id: human.id, handle: human.handle, reputation: human.reputation, claims: claims}
  end

  def upsert_profile_claim(binding, attrs) do
    key = Map.get(attrs, "key")

    claim =
      Repo.get_by(ProfileClaim, human_id: binding.human_id, key: key) ||
        %ProfileClaim{human_id: binding.human_id}

    claim
    |> ProfileClaim.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def upsert_contact_field(binding, attrs) do
    kind = Map.get(attrs, "kind")

    field =
      Repo.get_by(AgentSocial.Identity.ContactField, human_id: binding.human_id, kind: kind) ||
        %AgentSocial.Identity.ContactField{human_id: binding.human_id}

    field
    |> AgentSocial.Identity.ContactField.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def get_policy(human_id), do: Repo.get_by!(Policy, human_id: human_id)

  def update_policy(binding, attrs) do
    binding.human_id
    |> get_policy()
    |> Policy.changeset(attrs)
    |> Repo.update()
  end

  def search_profiles(viewer_id, query_text, opts \\ []) when is_binary(query_text) do
    limit = opts |> Keyword.get(:limit, 20) |> min(50) |> max(1)
    viewer_modes = get_policy(viewer_id).relationship_modes

    blocked_ids =
      from block in "blocks",
        where:
          field(block, :blocker_human_id) == type(^viewer_id, Ecto.UUID) or
            field(block, :blocked_human_id) == type(^viewer_id, Ecto.UUID),
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            field(block, :blocker_human_id),
            type(^viewer_id, Ecto.UUID),
            field(block, :blocked_human_id),
            field(block, :blocker_human_id)
          )

    ids =
      from(human in Human,
        join: claim in ProfileClaim,
        on: claim.human_id == human.id,
        join: policy in Policy,
        on: policy.human_id == human.id,
        where: human.status == "active" and human.id != ^viewer_id,
        where: human.id not in subquery(blocked_ids),
        where: claim.rankable == true and claim.visibility in ["public", "network"],
        where: fragment("? && ?", policy.relationship_modes, ^viewer_modes),
        where:
          fragment(
            "to_tsvector('simple', ? || ' ' || ?::text) @@ websearch_to_tsquery('simple', ?)",
            human.handle,
            claim.value,
            ^query_text
          ),
        group_by: human.id,
        order_by: [desc: human.reputation, asc: human.handle],
        limit: ^limit,
        select: human.id
      )
      |> Repo.all()

    Enum.map(ids, &get_profile(&1, viewer_id))
  end

  def revoke_binding(binding) do
    binding
    |> AgentBinding.changeset(%{active: false, revoked_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def delete_account(binding) do
    delete_human(binding.human_id, binding.id)
  end

  def delete_human(human_id, agent_binding_id \\ nil) do
    now = DateTime.utc_now()
    purge_after = DateTime.add(now, 30, :day)

    Multi.new()
    |> Multi.update_all(:revoke, from(b in AgentBinding, where: b.human_id == ^human_id),
      set: [active: false, revoked_at: now]
    )
    |> Multi.update_all(:human, from(h in Human, where: h.id == ^human_id),
      set: [status: "deleting", deleted_at: now, purge_after: purge_after]
    )
    |> Multi.update_all(
      :hide_content,
      from(c in AgentSocial.Social.ContentEnvelope,
        where: c.author_human_id == ^human_id
      ),
      set: [deleted_at: now]
    )
    |> Multi.insert(
      :audit,
      Operations.audit_changeset(%{
        actor_human_id: human_id,
        agent_binding_id: agent_binding_id,
        event_type: "identity.deletion_started",
        resource_type: "human",
        resource_id: human_id,
        metadata: %{purge_after: DateTime.to_iso8601(purge_after)}
      })
    )
    |> Multi.run(:purge_job, fn _repo, _changes ->
      %{human_id: human_id}
      |> AgentSocial.Lifecycle.DeletionWorker.new(scheduled_at: purge_after)
      |> Oban.insert()
    end)
    |> Repo.transaction()
  end

  defp complete_enrollment(challenge, oidc_subject) do
    case Repo.get_by(Human, email_hash: challenge.email_hash) do
      %Human{} = human -> complete_recovery(challenge, human, oidc_subject)
      nil -> complete_new_enrollment(challenge, oidc_subject)
    end
  end

  defp complete_new_enrollment(challenge, oidc_subject) do
    human_id = Ecto.UUID.generate()
    raw_token = issue_bearer_token(human_id)
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(:human, fn _ ->
      %Human{id: human_id, email_hash: challenge.email_hash}
      |> Human.changeset(%{
        handle: challenge.handle,
        oidc_subject: oidc_subject,
        email: challenge.email,
        age_attested_at: now,
        verified_at: now,
        terms_version: challenge.terms_version,
        terms_accepted_at: now,
        guidelines_version: challenge.guidelines_version,
        guidelines_accepted_at: now
      })
    end)
    |> Multi.insert(:binding, fn %{human: human} ->
      %AgentBinding{human_id: human.id}
      |> AgentBinding.changeset(%{
        public_key: challenge.public_key,
        token_digest: digest(raw_token),
        client_name: challenge.client_name,
        scopes: @default_scopes,
        key_version: 1
      })
    end)
    |> Multi.insert(:policy, fn %{human: human} ->
      %Policy{human_id: human.id}
      |> Policy.changeset(%{relationship_modes: AgentSocial.Types.relationship_modes()})
    end)
    |> Multi.update_all(
      :consume_challenge,
      from(c in EnrollmentChallenge, where: c.id == ^challenge.id),
      set: [consumed_at: now]
    )
    |> Multi.insert(:audit, fn %{human: human, binding: binding, policy: policy} ->
      Operations.audit_changeset(%{
        actor_human_id: human.id,
        agent_binding_id: binding.id,
        agent_key_version: binding.key_version,
        client_id: binding.client_id || binding.client_name,
        policy_version: policy.version,
        event_type: "identity.enrolled",
        resource_type: "human",
        resource_id: human.id,
        result_state: %{status: human.status, active_binding: true},
        metadata: %{
          client_name: binding.client_name,
          terms_version: challenge.terms_version,
          guidelines_version: challenge.guidelines_version,
          human_confirmation: "email_otp_relay"
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{human: human, binding: binding}} ->
        notify_human_control(human)
        {:ok, %{human: human, binding: binding, token: raw_token}}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  defp complete_recovery(challenge, human, oidc_subject) do
    raw_token = issue_bearer_token(human.id)
    now = DateTime.utc_now()
    policy_version = get_policy(human.id).version

    if String.downcase(human.handle) != String.downcase(challenge.handle) do
      {:error, :recovery_identity_mismatch}
    else
      Multi.new()
      |> Multi.run(:human, fn repo, _ ->
        locked = repo.one(from h in Human, where: h.id == ^human.id, lock: "FOR UPDATE")

        if locked.status == "active" do
          {:ok, locked}
        else
          {:error, :identity_unavailable}
        end
      end)
      |> Multi.update_all(
        :revoke_previous,
        from(binding in AgentBinding, where: binding.human_id == ^human.id and binding.active),
        set: [active: false, revoked_at: now, updated_at: now]
      )
      |> Multi.run(:key_version, fn repo, _ ->
        version =
          repo.one(
            from binding in AgentBinding,
              where: binding.human_id == ^human.id,
              select: max(binding.key_version)
          ) || 0

        {:ok, version + 1}
      end)
      |> Multi.insert(:binding, fn %{key_version: key_version} ->
        %AgentBinding{human_id: human.id}
        |> AgentBinding.changeset(%{
          public_key: challenge.public_key,
          token_digest: digest(raw_token),
          client_name: challenge.client_name,
          scopes: @default_scopes,
          key_version: key_version
        })
      end)
      |> Multi.update_all(
        :consume_challenge,
        from(c in EnrollmentChallenge, where: c.id == ^challenge.id),
        set: [consumed_at: now]
      )
      |> Multi.update_all(
        :link_oidc,
        from(h in Human, where: h.id == ^human.id and is_nil(h.oidc_subject)),
        set: [oidc_subject: oidc_subject, updated_at: now]
      )
      |> Multi.update(:policy_acceptance, fn %{human: locked} ->
        Human.changeset(locked, %{
          terms_version: challenge.terms_version,
          terms_accepted_at: now,
          guidelines_version: challenge.guidelines_version,
          guidelines_accepted_at: now
        })
      end)
      |> Multi.insert(:audit, fn %{binding: binding} ->
        Operations.audit_changeset(%{
          actor_human_id: human.id,
          agent_binding_id: binding.id,
          agent_key_version: binding.key_version,
          client_id: binding.client_id || binding.client_name,
          policy_version: policy_version,
          event_type: "identity.agent_recovered",
          resource_type: "human",
          resource_id: human.id,
          result_state: %{status: human.status, active_binding: true},
          metadata: %{
            client_name: binding.client_name,
            key_version: binding.key_version,
            terms_version: challenge.terms_version,
            guidelines_version: challenge.guidelines_version,
            human_confirmation: "email_otp_relay"
          }
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{binding: binding}} ->
          recovered_human = Repo.get!(Human, human.id)
          notify_human_control(recovered_human)
          {:ok, %{human: recovered_human, binding: binding, token: raw_token}}

        {:error, step, reason, _} ->
          {:error, {step, reason}}
      end
    end
  end

  defp notify_human_control(human) do
    control_token = AgentSocial.HumanControls.token_for(human)
    control_url = AgentSocialWeb.Endpoint.url() <> "/human/" <> control_token
    :ok = AgentSocial.Notifier.human_control_link(human.email, control_url)
  end

  defp public_url(path), do: AgentSocialWeb.Endpoint.url() <> path

  defp validate_challenge(challenge, attrs) do
    cond do
      not is_nil(challenge.consumed_at) ->
        {:error, :challenge_consumed}

      DateTime.before?(challenge.expires_at, DateTime.utc_now()) ->
        {:error, :challenge_expired}

      not is_binary(attrs["otp"]) ->
        {:error, :invalid_otp}

      not Plug.Crypto.secure_compare(challenge.otp_digest, digest(attrs["otp"])) ->
        {:error, :invalid_otp}

      true ->
        :ok
    end
  end

  defp fetch_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp enrollment_identity_available(email, handle) do
    normalized_handle = String.downcase(handle)
    by_email = Repo.get_by(Human, email_hash: email_hash(email))
    by_handle = Repo.get_by(Human, handle: normalized_handle)

    cond do
      is_nil(by_email) and is_nil(by_handle) -> :ok
      by_email && String.downcase(by_email.handle) == normalized_handle -> :ok
      by_email -> {:error, :identity_unavailable}
      by_handle -> {:error, :handle_unavailable}
    end
  end

  defp decode_sized(value, size) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == size -> {:ok, decoded}
      _ -> {:error, :invalid_encoded_value}
    end
  end

  defp decode_sized(_, _), do: {:error, :invalid_encoded_value}
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
  defp email_hash(email), do: email |> normalize_email() |> digest()
  defp digest(value), do: :crypto.hash(:sha256, value)

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp issue_bearer_token(human_id) do
    now = System.system_time(:second)

    claims = %{
      "sub" => human_id,
      "scopes" => @default_scopes,
      "iat" => now,
      "exp" => now + 365 * 86_400,
      "jti" => random_token(16)
    }

    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, bearer_secret(), payload)
      |> Base.url_encode64(padding: false)

    "ags_" <> payload <> "." <> signature
  end

  defp bearer_secret do
    Application.fetch_env!(:agent_social, :agent_bearer_secret)
  end

  defp auth_config(key, default),
    do: Application.get_env(:agent_social, :auth, []) |> Keyword.get(key, default)

  defp reveal_otp?,
    do: Application.get_env(:agent_social, :reveal_enrollment_otp, false)

  defp connected?(human_id, viewer_id) do
    Repo.exists?(
      from connection in "connections",
        where:
          field(connection, :status) == "active" and
            ((field(connection, :human_a_id) == type(^human_id, Ecto.UUID) and
                field(connection, :human_b_id) == type(^viewer_id, Ecto.UUID)) or
               (field(connection, :human_a_id) == type(^viewer_id, Ecto.UUID) and
                  field(connection, :human_b_id) == type(^human_id, Ecto.UUID)))
    )
  end
end
