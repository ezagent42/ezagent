defmodule Mix.Tasks.Ezagent.Session.RepairTemplateConfig do
  @shortdoc "Rebuild a session's freeze-pinned template configuration and routing rules"
  @moduledoc """
  Repairs an existing session from its freeze-pinned session template.

  Unlike `mix ezagent.session.reinstall_socialware`, this re-materializes the
  complete template declaration: member roles, routing rules, and installed
  configuration. Use it when an existing session has lost template-managed
  routing configuration.

  ## Usage

      mix ezagent.session.repair_template_config <session_uri>
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [session_uri_str | _] when is_binary(session_uri_str) and session_uri_str != "" ->
        session_uri = Ezagent.Session.MixTaskUriArg.parse_session_uri!(session_uri_str)

        workspace_uri =
          case Ezagent.Capability.workspace_of(session_uri) do
            %URI{} = workspace_uri -> workspace_uri
            :any -> Mix.raise("cannot derive workspace from #{URI.to_string(session_uri)}")
          end

        with {:ok, _pid} <- Ezagent.SpawnRegistry.ensure_live(session_uri),
             {:ok, %URI{} = owner} <- Ezagent.Entity.Session.owner(session_uri),
             {:ok, ^session_uri, _meta} <-
               EzagentDomainInstanceMessage.SessionCreator.repair_orchestrator(
                 session_uri,
                 {workspace_uri, owner}
               ) do
          Mix.shell().info("repaired template configuration for #{URI.to_string(session_uri)}")
        else
          {:error, reason} ->
            Mix.raise("template configuration repair failed: #{inspect(reason)}")

          other ->
            Mix.raise("template configuration repair failed: #{inspect(other)}")
        end

      _ ->
        Mix.raise("Usage: mix ezagent.session.repair_template_config <session_uri>")
    end
  end

end
