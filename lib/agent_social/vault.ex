defmodule AgentSocial.Vault do
  @moduledoc "Encryption vault for contact and webhook secrets."
  use Cloak.Vault, otp_app: :agent_social
end
