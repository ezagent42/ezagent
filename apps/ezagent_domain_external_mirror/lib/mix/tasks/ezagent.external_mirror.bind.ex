defmodule Mix.Tasks.Ezagent.ExternalMirror.Bind do
  @shortdoc "Bind a session to an external adapter target (SPEC §9 PR-EM-5)"
  @moduledoc """
  Bind `(adapter_id, target_id)` on `session_uri` via the
  `Ezagent.ExternalMirror.bind/4` facade. Same code path as the
  `/admin/sessions/:id/external_mirror` LiveView from PR-EM-4 — the
  facade enforces the two-step Check 1 (session bind cap) + Check 2
  (per-adapter allow cap) + Check 3 (target ownership check) before
  dispatching `:bind` to the Session Kind.

  ## Usage

      mix ezagent.external_mirror.bind <session_uri> <adapter_id> <target_id> [opts]

  ## Options

      --as <user_uri>       Run AS this user (default $EZAGENT_AS_USER
                            or entity://user/system/admin).
      --metadata key=val    Optional binding-time metadata (repeatable;
                            forwarded to the adapter's Binding.init/1
                            as `opts`).

  ## Examples

      mix ezagent.external_mirror.bind \\
        session://default/team-alpha/standup \\
        feishu \\
        oc_lark_abc123

      mix ezagent.external_mirror.bind \\
        session://default/team-alpha/standup \\
        feishu \\
        oc_lark_abc123 \\
        --as entity://user/team-alpha/alice \\
        --metadata silent_mode=true

  ## Exit codes

  - `0` on success
  - `1` on any error (caller missing cap, adapter not registered,
    target ownership check denial, timeout, dispatch error)

  ## Errors surfaced verbatim (P18)

  The facade's error atoms reach stderr unchanged:

  - `:unauthorized` — caller missing session bind cap (Check 1)
  - `:adapter_not_authorized` — caller missing per-adapter allow cap (Check 2)
  - `:unknown_adapter` — adapter id not in AdapterRegistry
  - `{:target_ownership_denied, reason}` — adapter's
    `target_ownership_check/2` denied (Check 3)
  - `:target_check_timeout` — Check 3 exceeded
    `target_ownership_check_timeout/0` (default 5000ms)
  - `:cross_workspace_denied` — caller / session workspace mismatch

  ## Client-side cap check

  Per SPEC §9 PR-EM-5 the task verifies the caller holds the session
  `:bind` cap (Check 1) BEFORE dispatching — operators get
  `:unauthorized` immediately on the CLI rather than after
  round-tripping through the runtime.
  """

  use Mix.Task

  alias Mix.Tasks.Ezagent.ExternalMirror.CLI

  @impl Mix.Task
  def run(argv) do
    {positional, %{as: as_uri, metadata: metadata, help?: help?}} = CLI.parse_argv(argv)

    cond do
      help? ->
        Mix.shell().info(@moduledoc)

      length(positional) != 3 ->
        Mix.shell().error(
          "usage: mix ezagent.external_mirror.bind <session_uri> <adapter_id> <target_id> " <>
            "[--as <user_uri>] [--metadata k=v ...]"
        )

        Mix.raise("usage")

      true ->
        [session_uri_str, adapter_id, target_id] = positional
        session_uri = CLI.parse_session_uri(session_uri_str)

        CLI.ensure_app_started!()
        ctx = CLI.build_ctx(as_uri)

        # Client-side gate (SPEC §9 PR-EM-5 — "check caps client-side").
        :ok = CLI.require_session_cap!(ctx, session_uri, :bind)

        case Ezagent.ExternalMirror.bind(session_uri, adapter_id, target_id, metadata, ctx) do
          {:ok, %{binding_id: bid} = result} ->
            worker = Map.get(result, :worker_uri, "<n/a>")

            Mix.shell().info(
              "ok binding_id=#{bid} worker_uri=#{format_worker(worker)} " <>
                "session=#{URI.to_string(session_uri)} adapter=#{adapter_id} " <>
                "target=#{inspect(target_id)}"
            )

          {:error, reason} ->
            CLI.surface_error(reason)
        end
    end
  end

  defp format_worker(%URI{} = uri), do: URI.to_string(uri)
  defp format_worker(other), do: inspect(other)
end
