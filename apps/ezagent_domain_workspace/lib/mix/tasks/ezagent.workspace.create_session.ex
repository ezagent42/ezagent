defmodule Mix.Tasks.Ezagent.Workspace.CreateSession do
  @shortdoc "Create a session through Workspace.create_session/3"
  @moduledoc """
  Create a session through `Ezagent.Workspace.create_session/3` — the same
  authorized entry used by the LiveView "New session" form.

  ## Usage

      mix ezagent.workspace.create_session <workspace_name> <short_name> --template <template_name>

  ## Example

      mix ezagent.workspace.create_session system main --template default

  The workspace must already exist. This task intentionally does not
  auto-create arbitrary workspaces; use `mix ezagent.workspace.create <name>`
  first when bootstrapping a new workspace.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    _ = Application.ensure_all_started(:ezagent_plugin_cc)

    {opts, positional, _} = OptionParser.parse(args, strict: [template: :string])

    case positional do
      [workspace_name, short_name | _]
      when is_binary(workspace_name) and workspace_name != "" and is_binary(short_name) and
             short_name != "" ->
        create_session(workspace_name, short_name, Keyword.get(opts, :template, "default"))

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.workspace.create_session <workspace_name> <short_name> --template <template_name>

        Example:
          mix ezagent.workspace.create_session system main --template default
        """)
    end
  end

  defp create_session(workspace_name, short_name, template_name) do
    workspace_uri = workspace_name |> String.trim() |> Ezagent.URI.workspace()

    # System-principal elimination (#154, 2026-06-19) — the OPERATOR CLI runs
    # under the real genesis admin entity (`User.admin_uri/0`), NOT the
    # eliminated `system://mix-task` ambient wildcard. Shell access = admin
    # authority (in-VM trust §10.5), so the operator IS admin. The dispatch
    # carries an INLINE per-action `cap(:workspace, Workspace, :create_session)`
    # scoped to the target workspace (the step-5.5 authorizer) — tightest
    # least-privilege for this single non-grant dispatch; `granted_by` =
    # `admin_uri()` (a real entity per #154, provenance only on an inline
    # authorizer never routed through `Ezagent.Identity.Grant`).
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(workspace_uri, :workspace, :create_session)

    ctx =
      case Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
        {:ok, cap} -> %{caller: admin, caps: [cap]}
        {:error, reason} -> Mix.raise("create-session cap issuance failed: #{inspect(reason)}")
      end

    case Ezagent.Workspace.create_session(
           workspace_uri,
           %{short_name: String.trim(short_name), template_name: template_name},
           ctx
         ) do
      {:ok, result} ->
        session_uri = Map.fetch!(result, :session_uri)
        Mix.shell().info("✓ created #{URI.to_string(session_uri)}")

      {:error, reason} ->
        Mix.raise("create_session failed: #{inspect(reason)}")
    end
  end
end
