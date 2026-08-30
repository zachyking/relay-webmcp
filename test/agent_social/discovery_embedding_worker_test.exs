defmodule AgentSocial.Discovery.EmbeddingWorkerTest do
  use AgentSocial.DataCase

  alias AgentSocial.Discovery.EmbeddingWorker

  test "only rankable metadata is sent to the embedding provider" do
    previous = Application.get_env(:agent_social, :embeddings)

    Application.put_env(:agent_social, :embeddings,
      endpoint: "https://embeddings.example/v1/embeddings",
      model: "test-model",
      dimensions: 3,
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:agent_social, :embeddings, previous) end)

    Req.Test.expect(__MODULE__, fn conn ->
      body = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert body["input"] == Jason.encode!(%{"summary" => "safe metadata"})
      refute body["input"] =~ "opaque secret"
      Req.Test.json(conn, %{"data" => [%{"embedding" => [0.1, 0.2, 0.3]}]})
    end)

    assert {:ok, vector} = EmbeddingWorker.embed(%{"summary" => "safe metadata"})

    Pgvector.to_list(vector)
    |> Enum.zip([0.1, 0.2, 0.3])
    |> Enum.each(fn {actual, expected} -> assert_in_delta actual, expected, 0.000_001 end)
  end
end
