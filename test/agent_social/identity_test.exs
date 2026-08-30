defmodule AgentSocial.IdentityTest do
  use AgentSocial.DataCase

  alias AgentSocial.Identity
  alias AgentSocial.Identity.AgentBinding

  test "agent-led enrollment requires adult attestation, OTP, and Ed25519 proof" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    base = %{
      "email" => "owner@example.test",
      "handle" => "verified_owner",
      "client_name" => "Hermes",
      "public_key" => Base.url_encode64(public_key, padding: false)
    }

    assert {:error, :adult_attestation_required} = Identity.start_enrollment(base)
    {:ok, challenge} = Identity.start_enrollment(Map.put(base, "adult_attested", true))

    message = challenge.nonce <> ":" <> challenge.development_otp
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])

    assert {:ok, result} =
             Identity.finish_enrollment(%{
               "challenge_id" => challenge.challenge_id,
               "otp" => challenge.development_otp,
               "signature" => Base.url_encode64(signature, padding: false),
               "oidc_subject" => "zitadel-owner"
             })

    assert result.human.handle == "verified_owner"
    assert result.human.terms_version == AgentSocial.PlatformPolicies.version()
    assert result.human.guidelines_version == AgentSocial.PlatformPolicies.version()
    assert result.binding.key_version == 1
    assert Identity.get_policy(result.human.id).version == 1

    assert {:ok, updated_policy} =
             Identity.update_policy(result.binding, %{
               "daily_post_limit" => 12,
               "confirmation_requirements" => %{"public_post" => "always"}
             })

    assert updated_policy.version == 2
    assert updated_policy.confirmation_requirements == %{"public_post" => "always"}

    assert {:error, consent_changeset} =
             Identity.update_policy(result.binding, %{"require_intro_approval" => false})

    assert "cannot disable direct human consent" in errors_on(consent_changeset).require_intro_approval
    assert String.starts_with?(result.token, "ags_")
    assert {:ok, authenticated} = Identity.authenticate_token(result.token)
    assert authenticated.human_id == result.human.id

    assert {:error, :challenge_consumed} =
             Identity.finish_enrollment(%{
               "challenge_id" => challenge.challenge_id,
               "otp" => challenge.development_otp,
               "signature" => Base.url_encode64(signature, padding: false)
             })
  end

  test "database rejects a second active agent for one human" do
    actor = actor()

    changeset =
      %AgentBinding{human_id: actor.human.id}
      |> AgentBinding.changeset(%{
        public_key: :crypto.strong_rand_bytes(32),
        token_digest: :crypto.hash(:sha256, "different-token"),
        client_name: "replacement",
        scopes: actor.binding.scopes,
        key_version: 2
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert "has already been taken" in errors_on(changeset).human_id
  end

  test "OTP recovery rotates the agent key and revokes the previous credential" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, challenge} =
      Identity.start_enrollment(%{
        "email" => "recovery@example.test",
        "handle" => "recoverable_owner",
        "client_name" => "Codex",
        "public_key" => Base.url_encode64(public_key, padding: false),
        "adult_attested" => true
      })

    signature =
      :crypto.sign(
        :eddsa,
        :none,
        challenge.nonce <> ":" <> challenge.development_otp,
        [private_key, :ed25519]
      )

    {:ok, original} =
      Identity.finish_enrollment(%{
        "challenge_id" => challenge.challenge_id,
        "otp" => challenge.development_otp,
        "signature" => Base.url_encode64(signature, padding: false)
      })

    {new_public_key, new_private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, recovery} =
      Identity.start_enrollment(%{
        "email" => "recovery@example.test",
        "handle" => "recoverable_owner",
        "client_name" => "Claude Code",
        "public_key" => Base.url_encode64(new_public_key, padding: false),
        "adult_attested" => true
      })

    recovery_signature =
      :crypto.sign(
        :eddsa,
        :none,
        recovery.nonce <> ":" <> recovery.development_otp,
        [new_private_key, :ed25519]
      )

    assert {:ok, rotated} =
             Identity.finish_enrollment(%{
               "challenge_id" => recovery.challenge_id,
               "otp" => recovery.development_otp,
               "signature" => Base.url_encode64(recovery_signature, padding: false)
             })

    assert rotated.human.id == original.human.id
    assert rotated.binding.key_version == 2
    assert {:error, :unauthorized} = Identity.authenticate_token(original.token)
    assert {:ok, binding} = Identity.authenticate_token(rotated.token)
    assert binding.id == rotated.binding.id
  end
end
