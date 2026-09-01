defmodule AgentSocial.Notifier do
  @moduledoc "Delivery boundary for enrollment and approval messages."

  def enrollment_otp(email, otp, details) do
    deliver(%{
      template: "enrollment_otp",
      to: email,
      variables: Map.put(details, :otp, otp)
    })
  end

  def approval_link(email, action, url) do
    deliver(%{
      template: "human_approval",
      to: email,
      variables: %{action: action, url: url}
    })
  end

  def human_control_link(email, url, details \\ %{}) do
    deliver(%{
      template: "human_control",
      to: email,
      variables: Map.merge(%{url: url, expires_in_minutes: 60}, details)
    })
  end

  def safety_alert(email, details) do
    deliver(%{
      template: "safety_alert",
      to: email,
      variables: details
    })
  end

  defp deliver(message) do
    :agent_social
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:adapter)
    |> apply(:deliver, [message])
  end
end
