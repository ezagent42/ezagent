defmodule Mix.Tasks.Ezagent.Demo.SeedHelloFusion do
  @shortdoc "Reconstruct the complete committed Hello Fusion website"
  @moduledoc """
  Reconstructs `session://system/hello/fusion` and applies the complete Page and
  shell CSS committed under `ezagent_plugin_hello/priv/seed_page`.

  This command is designed for an independent or fresh database; it does not
  require an export or snapshot from another contributor.

      mix ezagent.demo.seed_hello_fusion
  """

  use Mix.Task

  alias EzagentPluginHello.FusionSeed

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case FusionSeed.run() do
      {:ok, %{session_uri: session_uri, turn_id: turn_id}} ->
        Mix.shell().info("""

        Hello Fusion website reconstructed (turn #{turn_id}):
          session: #{URI.to_string(session_uri)}
          public:  /hello/fusion
        """)

      {:error, reason} ->
        Mix.raise("could not reconstruct Hello Fusion website: #{inspect(reason)}")
    end
  end
end
