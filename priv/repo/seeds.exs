alias AgentSocial.Governance.ConfigurationVersion
alias AgentSocial.{Governance, Repo}

unless Repo.exists?(ConfigurationVersion) do
  %ConfigurationVersion{}
  |> ConfigurationVersion.changeset(%{
    version: 1,
    configuration: Governance.default_configuration(),
    status: "active",
    activated_at: DateTime.utc_now()
  })
  |> Repo.insert!()
end
