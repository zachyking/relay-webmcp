defmodule AgentSocial.Safety.AlertWorker do
  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 10,
    unique: [period: 86_400, keys: [:report_id]]

  alias AgentSocial.Notifier
  alias AgentSocial.Repo
  alias AgentSocial.Safety.Report

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id}}) do
    case Repo.get(Report, report_id) do
      nil ->
        :discard

      report ->
        operator = Application.fetch_env!(:agent_social, :operator)

        Notifier.safety_alert(operator[:security_email], %{
          report_id: report.id,
          reporter_human_id: report.reporter_human_id,
          subject_type: report.subject_type,
          subject_id: report.subject_id,
          category: report.category,
          details: report.details,
          created_at: DateTime.to_iso8601(report.inserted_at)
        })
    end
  end
end
