defmodule Mix.Tasks.Ezagent.Workspace.Create do
  @shortdoc "Create a new workspace via the same path as the operator UI"
  @moduledoc """
  Create a new workspace via `Ezagent.Workspace.create/2` — the SAME
  function the operator UI calls. CLI and UI share one code path; this task
  exists for parity per Allen 2026-05-25 directive (`CLI/UI 同源派生`).

  ## Usage

      mix ezagent.workspace.create <name>

  ## Example

      mix ezagent.workspace.create h2oslabs.com

  The workspace name is the URI authority — it must be DNS-host-shaped
  (alphanumeric plus `-` and `.`). The resulting URI is
  `workspace://<name>`.

  Exits non-zero on error so it composes with shell pipelines.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [name | _] when is_binary(name) and name != "" ->
        trimmed = String.trim(name)

        case Ezagent.Workspace.create(trimmed, %{}) do
          {:ok, _uri} ->
            Mix.shell().info("✓ created workspace #{trimmed}")

          {:error, reason} ->
            Mix.raise("create failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing workspace name.

        Usage:
          mix ezagent.workspace.create <name>

        Example:
          mix ezagent.workspace.create h2oslabs.com
        """)
    end
  end
end
