defmodule AgentSocial.EncryptedBinary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: AgentSocial.Vault
end
