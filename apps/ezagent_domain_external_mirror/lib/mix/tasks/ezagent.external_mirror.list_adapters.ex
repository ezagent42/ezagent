defmodule Mix.Tasks.Ezagent.ExternalMirror.ListAdapters do
  @shortdoc "List all registered ExternalMirror adapters (SPEC §9 PR-EM-5)"
  @moduledoc """
  List every adapter registered with
  `Ezagent.ExternalMirror.AdapterRegistry` (the operator-facing
  metadata view per SPEC §4.4).

  ## Caps exception (SPEC §9 PR-EM-1 + PR-EM-5)

  This is the ONE `external_mirror` command without a caps check.
  Per SPEC §4.4: "`list_adapters/0` returns the operator-facing
  adapter descriptor list" — pure registry metadata, no per-tenant
  data. SPEC §9 PR-EM-5 says "All commands check caps client-side"
  but PR-EM-1 (§4.4) defined `list_adapters/0` as unauthed; the
  intent is that operator-facing CLI tooling can enumerate
  registered adapter ids without holding any cap (otherwise a
  fresh user couldn't even discover what to bind).

  Codex r1 MED-3 (2026-05-25): documenting this exception
  explicitly so the discrepancy with PR-EM-5's "all commands"
  language is grep-able.

  All four other tasks (bind / unbind / list_bindings) DO enforce
  caps — see their moduledocs.

  ## Usage

      mix ezagent.external_mirror.list_adapters

  ## Output

      id              display_name                  description
      ----------------------------------------------------------------------------------
      feishu          Feishu (Lark)                 Mirror session messages to a Lark chat.

  ## Exit codes

  - `0` on success (always — empty list is not an error)

  ## See also

  - `mix ezagent.external_mirror.bind` / `unbind` / `list_bindings`
  - `Ezagent.ExternalMirror.list_adapters/0` (the facade)
  """

  use Mix.Task

  alias Mix.Tasks.Ezagent.ExternalMirror.CLI

  @impl Mix.Task
  def run(argv) do
    # `caller_required: false` — the admin default for caller URI is
    # legitimate here (only used for the audit row; no cap check
    # happens against this URI). All other tasks set the default
    # `caller_required: true` so missing `--as` raises.
    {positional, %{help?: help?}} = CLI.parse_argv(argv, caller_required: false)

    cond do
      help? ->
        Mix.shell().info(@moduledoc)

      positional != [] ->
        # codex r2 LOW (2026-05-25): reject stray positional args so
        # `mix ezagent.external_mirror.list_adapters garbage` doesn't
        # silently succeed. Operator-facing surface: every silent
        # drop is a future bug report.
        Mix.shell().error(
          "error: list_adapters takes no positional args; got: #{inspect(positional)}"
        )

        Mix.raise("unexpected positional args")

      true ->
        CLI.ensure_app_started!()
        adapters = Ezagent.ExternalMirror.list_adapters()
        Mix.shell().info(CLI.format_adapters(adapters))
    end
  end
end
