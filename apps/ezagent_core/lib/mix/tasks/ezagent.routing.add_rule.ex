defmodule Mix.Tasks.Ezagent.Routing.AddRule do
  @shortdoc "DEPRECATED — use `mix esr routing add_rule` (CLI/GUI audit HIGH-2)"
  @moduledoc """
  **DEPRECATED 2026-05-24 (CLI/GUI audit HIGH-2).**

  This legacy task bypasses dispatch — it writes directly to
  `RuleStore` with no CapBAC, no audit, no cross-workspace check. The
  GUI-side `routing_live.ex` correctly dispatches
  `system://routing/default?action=routing.add_rule` (`Ezagent.Behavior.Routing`).

  Use the auto-derived `mix esr` command instead:

      mix esr routing add_rule --uri system://routing/default \\
          --matcher mention:entity://agent/default/cc_builder \\
          --receivers session://default/default/architect

  `mix esr` runs in the same BEAM as the GUI (via distributed-Erlang
  RPC) — same dispatch path, same CapBAC gate, same audit row.

  This task remains as a no-op stub for the rest of this release
  cycle so existing shell scripts surface a clear migration message
  rather than silently writing un-gated rules. Will be deleted in
  the next release.

  Phase 3 admin tool to add a routing rule from the CLI.

  ## Usage

      mix ezagent.routing.add_rule <TableName> <matcher_spec> receivers:<uri1>,<uri2>

  ### Matcher specs

  - `mention:<uri>` — `Ezagent.Routing.Matcher.mention(uri)`
  - `from:<uri>`
  - `text_contains:<substring>`
  - `text_matches:<regex>`
  - `always` (no arg)

  ### Examples

      # text_contains rule: any urgent message → oncall session
      mix ezagent.routing.add_rule EzagentDomainChat.Routing.MentionRouting \\
          text_contains:urgent receivers:session://default/default/oncall

      # mention rule: @cc_builder → architect session
      mix ezagent.routing.add_rule EzagentDomainChat.Routing.MentionRouting \\
          mention:entity://agent/default/cc_builder receivers:session://default/default/architect

  ## Behavior

  1. Parses matcher_spec → `Ezagent.Routing.Matcher.matcher_tuple`
  2. Parses receivers → `[URI.t()]`
  3. Persists via `Ezagent.Routing.RuleStore.add/4`(created_by = nil for
     CLI; LV form will pass admin URI)
  4. Reloads the live `RoutingRegistry` table so the rule is in effect
     immediately (no restart needed)

  Phase 4 will add `mix ezagent.routing.list` / `mix ezagent.routing.delete`.
  """
  use Mix.Task

  alias Ezagent.Routing.{Matcher, RuleStore}

  @impl Mix.Task
  def run(_args) do
    Mix.raise("""
    DEPRECATED 2026-05-24 — `mix ezagent.routing.add_rule` bypassed
    dispatch (no CapBAC, no audit, no cross-workspace check). Use the
    auto-derived `mix esr` command instead, which runs in the same
    BEAM as the GUI via distributed-Erlang RPC and goes through the
    standard dispatch pipeline:

        mix esr routing add_rule \\
            --uri system://routing/default \\
            --matcher mention:entity://agent/default/cc_builder \\
            --receivers session://default/default/architect

    See `Ezagent.Behavior.Routing.interface/0` for the full action
    schema. The GUI's /routing page uses the SAME dispatch path.

    CLI/GUI parity audit reference:
    docs/notes/2026-05-24-cli-gui-parity-audit.md (HIGH-2).
    """)
  end

  defp parse_table(s) when is_binary(s) do
    try do
      {:ok, String.to_existing_atom("Elixir." <> s)}
    rescue
      ArgumentError -> {:error, {:unknown_table, s}}
    end
  end

  defp parse_matcher("always"), do: {:ok, Matcher.always()}
  defp parse_matcher("mention:" <> uri), do: {:ok, Matcher.mention(uri)}
  defp parse_matcher("from:" <> uri), do: {:ok, Matcher.from(uri)}
  defp parse_matcher("text_contains:" <> s), do: {:ok, Matcher.text_contains(s)}

  defp parse_matcher("text_matches:" <> re) do
    try do
      {:ok, Matcher.text_matches(re)}
    rescue
      _ -> {:error, {:bad_regex, re}}
    end
  end

  defp parse_matcher(other), do: {:error, {:unknown_matcher, other}}

  defp parse_receivers(csv), do: String.split(csv, ",", trim: true)
end
