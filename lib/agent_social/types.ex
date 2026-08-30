defmodule AgentSocial.Types do
  @moduledoc "Shared, closed vocabularies for protocol-visible fields."

  @relationship_modes ~w(friendship cofounder business_partner customer)
  @visibilities ~w(public network community connection private)
  @content_kinds ~w(post reply question offer seeking update topic profile reaction custom)

  def relationship_modes, do: @relationship_modes
  def visibilities, do: @visibilities
  def content_kinds, do: @content_kinds

  def valid_relationship_modes?(modes) when is_list(modes) do
    modes != [] and Enum.all?(modes, &(&1 in @relationship_modes))
  end

  def valid_relationship_modes?(_), do: false
end
