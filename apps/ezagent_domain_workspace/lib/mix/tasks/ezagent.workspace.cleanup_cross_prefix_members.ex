defmodule Mix.Tasks.Ezagent.Workspace.CleanupCrossPrefixMembers do
  @shortdoc "Scan workspaces for members whose URI workspace segment doesn't match — log + optionally strip"

  @moduledoc """
  Task #55 (Allen 2026-05-27) — workspace prefix invariant cleanup.

  Scans every workspace in `Ezagent.Workspace.Store` and reports
  members whose URI workspace segment does NOT match the workspace
  name. The Behavior-level validator (`:add_member` action) blocks
  new violations from landing; this task cleans up rows that landed
  before the gate was in place.

  Empirically observed violator (Allen 2026-05-27 02:47 via RPC):
  the `h2oslabs` workspace row carried `entity://user/system/linyilun`
  as a member — a cross-prefix leak.

  ## URI shape (SPEC v3 §3 + §5.15)

      entity://<type>/<workspace>/<name>

  A member URI `entity://user/system/linyilun` inside workspace
  `h2oslabs` is REJECTED because the URI's workspace segment
  (`system`) doesn't match the workspace name (`h2oslabs`).

  ## Usage

      # Audit only — default. Prints violators, no DB write.
      mix ezagent.workspace.cleanup_cross_prefix_members

      # or explicit
      mix ezagent.workspace.cleanup_cross_prefix_members --dry-run

      # Strip violators from each workspace's member set.
      mix ezagent.workspace.cleanup_cross_prefix_members --apply

  `--apply` dispatches `Behavior.Workspace.:remove_cross_prefix_members`
  via `Ezagent.Workspace.remove_cross_prefix_members/1` — the action
  body classifies + mutates the live slice atomically under the
  Workspace Kind GenServer, and the facade persists the kept set in
  the same call so the DB + slice stay aligned. NO restart needed
  post-`--apply`.

  Task #55 round-2 codex HIGH-2 (2026-05-27): the previous version
  wrote directly to `Ezagent.Workspace.Store.update_members/2` after
  computing `kept` from the DB row. Two problems:
    1. Race: a legitimate concurrent `add_member` between the scan
       (line 79 read) + write (line 169 update) would be lost — the
       facade's `Store.update_members/2` overwrites the full member
       list with the stale kept set.
    2. Stale slice: the live Workspace Kind's `:workspace` slice cache
       isn't refreshed from DB; operator had to SIGHUP / restart for
       subsequent `:list_members` dispatches to see the cleanup.
  The new dispatch-owned action closes both gaps.

  Exit code 0 even when violators are present — this is an audit
  tool, not a CI gate. The CI gate is the Behavior validator.

  ## Output

      ⚠ workspace://h2oslabs has 1 cross-prefix member(s):
        - entity://user/system/linyilun  (workspace segment 'system' ≠ 'h2oslabs')
      ✓ workspace://system clean (5 members)

      Summary: 2 workspaces scanned, 1 violator across 1 workspace.
      Run with --apply to strip.

  ## Why audit-by-default

  - "Don't delete what the operator might still want" — per
    Allen's brief: `logs violators (don't auto-delete; operator
    decides)`.
  - A wrong-prefix member usually means a flawed admin gesture
    (cross-tenant assist), not a malicious actor; the operator
    deserves a chance to re-add the member to the CORRECT
    workspace before the row vanishes.
  """

  use Mix.Task

  require Logger

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [apply: :boolean, dry_run: :boolean])

    apply? = Keyword.get(opts, :apply, false)
    # `--dry-run` is the default; surface it in the banner regardless.
    _dry_run? = not apply?

    workspaces = Ezagent.Workspace.Store.list_all()
    {violator_count, workspace_count_with_violators} = scan_and_report(workspaces, apply?)

    Mix.shell().info(
      "\nSummary: #{length(workspaces)} workspaces scanned, " <>
        "#{violator_count} violator(s) across #{workspace_count_with_violators} workspace(s)."
    )

    if violator_count > 0 and not apply? do
      Mix.shell().info("Run with --apply to strip them.")
    end

    :ok
  end

  defp scan_and_report(workspaces, apply?) do
    workspaces
    |> Enum.reduce({0, 0}, fn workspace, {viol_count, ws_count} ->
      case classify_members(workspace) do
        {[], _kept} ->
          Mix.shell().info(
            "✓ workspace://#{workspace.name} clean (#{length(workspace.members)} members)"
          )

          {viol_count, ws_count}

        {violators, _kept} ->
          report_violators(workspace.name, violators)

          if apply? do
            apply_strip(workspace.name)
          end

          {viol_count + length(violators), ws_count + 1}
      end
    end)
  end

  # Returns `{violators, kept}` — both lists of `URI.t()`.
  defp classify_members(%{name: workspace_name, members: members}) when is_list(members) do
    Enum.split_with(members, fn member ->
      cross_prefix?(member, workspace_name)
    end)
  end

  defp classify_members(_), do: {[], []}

  # A member is a violator under any of:
  #   - not an `entity://` URI (`system://`, `workspace://`, …) —
  #     non-entity members are flagged outright per the
  #     `:non_entity_member` rule the Behavior validator returns.
  #   - `entity://` URI carrying `?query` or `#fragment` — instance
  #     form is required for membership identity (task #55 round-2
  #     codex r2 HIGH-1 follow-up).
  #   - `entity://` URI whose workspace segment doesn't match
  #     `workspace_name`, including 4+ segment / trailing slash / non
  #     `user|agent` host shapes that pre-canonicalize parsing
  #     admitted (HIGH-1 fix).
  #
  # Task #55 round-2 codex r2 review HIGH-2 follow-up — keeps the
  # mix task's pre-scan in lockstep with the Behavior's classifier so
  # an `--apply` invocation that the pre-scan reports as clean cannot
  # silently skip URIs the dispatched `:remove_cross_prefix_members`
  # would have stripped.
  defp cross_prefix?(%URI{scheme: "entity"} = member, workspace_name) do
    cond do
      member.query != nil -> true
      member.fragment != nil -> true
      not (is_binary(member.host) and member.host in ["user", "agent"]) -> true
      not is_binary(member.path) -> true
      true -> entity_path_cross_prefix?(member.path, workspace_name)
    end
  end

  defp cross_prefix?(%URI{}, _workspace_name), do: true

  defp cross_prefix?(_other, _workspace_name), do: true

  defp entity_path_cross_prefix?("/" <> rest, workspace_name) do
    case String.split(rest, "/") do
      [^workspace_name, name] when name != "" -> false
      _ -> true
    end
  end

  defp entity_path_cross_prefix?(_, _), do: true

  defp report_violators(workspace_name, violators) do
    Mix.shell().info(
      "⚠ workspace://#{workspace_name} has #{length(violators)} cross-prefix member(s):"
    )

    Enum.each(violators, fn %URI{} = member ->
      Mix.shell().info(
        "  - #{URI.to_string(member)}  " <>
          "(#{violation_reason(member, workspace_name)})"
      )
    end)
  end

  defp violation_reason(%URI{scheme: "entity", query: q}, _workspace_name)
       when is_binary(q) and q != "",
       do: "non-canonical URI (query string present)"

  defp violation_reason(%URI{scheme: "entity", fragment: f}, _workspace_name)
       when is_binary(f) and f != "",
       do: "non-canonical URI (fragment present)"

  defp violation_reason(%URI{scheme: "entity", host: host}, _workspace_name)
       when is_binary(host) and host not in ["user", "agent"],
       do: "bad entity type '#{host}' (must be 'user' or 'agent')"

  defp violation_reason(%URI{scheme: "entity", path: "/" <> rest}, workspace_name) do
    case String.split(rest, "/", parts: 2) do
      [other_ws, _name] -> "workspace segment '#{other_ws}' ≠ '#{workspace_name}'"
      _ -> "malformed entity URI (not 3-segment)"
    end
  end

  defp violation_reason(%URI{scheme: scheme}, _workspace_name) when is_binary(scheme),
    do: "non-entity member (scheme '#{scheme}')"

  defp violation_reason(_, _), do: "unrecognized URI shape"

  # Task #55 round-2 codex HIGH-2 (2026-05-27) — dispatch-owned strip.
  # `Ezagent.Workspace.remove_cross_prefix_members/1` classifies +
  # mutates the slice + persists the kept set in one dispatch round,
  # atomic under the Workspace Kind GenServer's serialized message
  # queue. Replaces the previous direct `Store.update_members/2`
  # write that raced concurrent `add_member` calls and left the slice
  # stale until restart.
  defp apply_strip(workspace_name) do
    case Ezagent.Workspace.remove_cross_prefix_members(workspace_name) do
      {:ok, %{removed: removed, kept_count: kept_count}} ->
        Mix.shell().info(
          "  → stripped #{length(removed)} member(s) via dispatch. " <>
            "workspace://#{workspace_name} now has #{kept_count} member(s)."
        )

      {:error, reason} ->
        Mix.shell().error(
          "  ! remove_cross_prefix_members dispatch failed for workspace://" <>
            "#{workspace_name}: #{inspect(reason)}"
        )
    end
  end
end
