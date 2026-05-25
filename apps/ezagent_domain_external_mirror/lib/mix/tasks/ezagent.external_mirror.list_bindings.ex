defmodule Mix.Tasks.Ezagent.ExternalMirror.ListBindings do
  @shortdoc "List bindings on a session (SPEC §9 PR-EM-5)"
  @moduledoc """
  List every ExternalMirror binding on `session_uri` via the
  `Ezagent.ExternalMirror.list_bindings/2` facade. Same dispatch
  path as the LiveView from PR-EM-4 — CapBAC step 5.5 enforces the
  session-level `:list_bindings` cap.

  ## Usage

      mix ezagent.external_mirror.list_bindings <session_uri> [--as <user_uri>]

  ## Output

      adapter_id      target_id                       bound_at                       binding_id
      ----------------------------------------------------------------------------------------------------
      feishu          "oc_lark_abc123"                2026-05-25T01:00:00.000000Z    feishu/oc_lark_abc123

  ## Exit codes

  - `0` on success (empty list is success — no bindings yet)
  - `1` on any error

  ## Errors surfaced verbatim (P18)

  - `:unauthorized` — caller missing session `:list_bindings` cap
  - `:cross_workspace_denied` — caller / session workspace mismatch
  - `:not_ready` / `:no_such_actor` — session not running
  """

  use Mix.Task

  alias Mix.Tasks.Ezagent.ExternalMirror.CLI

  @impl Mix.Task
  def run(argv) do
    {positional, %{as: as_uri, help?: help?}} = CLI.parse_argv(argv)

    cond do
      help? ->
        Mix.shell().info(@moduledoc)

      length(positional) != 1 ->
        Mix.shell().error(
          "usage: mix ezagent.external_mirror.list_bindings <session_uri> [--as <user_uri>]"
        )

        Mix.raise("usage")

      true ->
        [session_uri_str] = positional
        session_uri = CLI.parse_session_uri(session_uri_str)

        CLI.ensure_app_started!()
        ctx = CLI.build_ctx(as_uri)

        :ok = CLI.require_session_cap!(ctx, session_uri, :list_bindings)

        case Ezagent.ExternalMirror.list_bindings(session_uri, ctx) do
          {:ok, bindings} ->
            Mix.shell().info(CLI.format_bindings(bindings))

          {:error, reason} ->
            CLI.surface_error(reason)
        end
    end
  end
end
