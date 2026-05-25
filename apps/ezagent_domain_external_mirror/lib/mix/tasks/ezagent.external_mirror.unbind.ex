defmodule Mix.Tasks.Ezagent.ExternalMirror.Unbind do
  @shortdoc "Unbind a session from an external adapter target (SPEC §9 PR-EM-5)"
  @moduledoc """
  Unbind `(adapter_id, target_id)` from `session_uri` via the
  `Ezagent.ExternalMirror.unbind/3` facade. Same code path as the
  `/admin/sessions/:id/external_mirror` LiveView from PR-EM-4 — the
  facade dispatches `:unbind` on the Session Kind which removes the
  binding from the slice, deletes the projection row, and terminates
  the Worker via the two-tier `WorkerSpawn.terminate/3`.

  Idempotent: unbinding an already-absent binding returns
  `{:ok, %{ok: true, unbound: false}}` (success, no-op).

  ## Usage

      mix ezagent.external_mirror.unbind <session_uri> <adapter_id> <target_id> [--as <user_uri>]

  ## Example

      mix ezagent.external_mirror.unbind \\
        session://default/team-alpha/standup \\
        feishu \\
        oc_lark_abc123

  ## Exit codes

  - `0` on success (including idempotent no-op)
  - `1` on any error

  ## Errors surfaced verbatim (P18)

  - `:unauthorized` — caller missing session bind cap (same cap shape
    as `:bind`; `:unbind` shares Cap 1)
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

      length(positional) != 3 ->
        Mix.shell().error(
          "usage: mix ezagent.external_mirror.unbind <session_uri> <adapter_id> <target_id> " <>
            "[--as <user_uri>]"
        )

        Mix.raise("usage")

      true ->
        [session_uri_str, adapter_id, target_id] = positional
        session_uri = CLI.parse_session_uri(session_uri_str)

        CLI.ensure_app_started!()
        ctx = CLI.build_ctx(as_uri)

        # Client-side gate. `:unbind` shares the `Behavior.ExternalMirror`
        # cap with `:bind` (SPEC §4.2 — both gated by Cap 1) so we
        # reuse the `:bind` action atom for the cap lookup.
        :ok = CLI.require_session_cap!(ctx, session_uri, :bind)

        case Ezagent.ExternalMirror.unbind(session_uri, adapter_id, target_id, ctx) do
          {:ok, %{unbound: true}} ->
            Mix.shell().info(
              "ok session=#{URI.to_string(session_uri)} adapter=#{adapter_id} " <>
                "target=#{inspect(target_id)} unbound=true"
            )

          {:ok, %{unbound: false}} ->
            Mix.shell().info(
              "ok session=#{URI.to_string(session_uri)} adapter=#{adapter_id} " <>
                "target=#{inspect(target_id)} unbound=false (no such binding — idempotent no-op)"
            )

          {:ok, other} ->
            Mix.shell().info("ok #{inspect(other)}")

          {:error, reason} ->
            CLI.surface_error(reason)
        end
    end
  end
end
