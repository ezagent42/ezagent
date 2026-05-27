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

  `--apply` writes via `Ezagent.Workspace.Store.update_members/2`;
  the operator must SIGHUP or restart the running Workspace Kind for
  the slice to refresh from DB (slices are in-memory caches of the
  persisted member list).

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

        {violators, kept} ->
          report_violators(workspace.name, violators)

          if apply? do
            apply_strip(workspace.name, kept)
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

  # A member is a cross-prefix violator when:
  #   - it's an `entity://` URI AND
  #   - its workspace segment != the containing workspace name
  # `system://` / `workspace://` members are flagged as non-entity
  # violators (a workspace member should always be an entity per the
  # `:non_entity_member` rule the Behavior validator returns).
  defp cross_prefix?(%URI{scheme: "entity", path: "/" <> rest}, workspace_name) do
    case String.split(rest, "/", parts: 2) do
      [^workspace_name, _name] -> false
      [_other_ws, _name] -> true
      _ -> true
    end
  end

  defp cross_prefix?(%URI{}, _workspace_name), do: true

  defp cross_prefix?(_other, _workspace_name), do: true

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

  defp violation_reason(%URI{scheme: "entity", path: "/" <> rest}, workspace_name) do
    case String.split(rest, "/", parts: 2) do
      [other_ws, _name] -> "workspace segment '#{other_ws}' ≠ '#{workspace_name}'"
      _ -> "malformed entity URI (not 3-segment)"
    end
  end

  defp violation_reason(%URI{scheme: scheme}, _workspace_name) when is_binary(scheme),
    do: "non-entity member (scheme '#{scheme}')"

  defp violation_reason(_, _), do: "unrecognized URI shape"

  defp apply_strip(workspace_name, kept_members) do
    case Ezagent.Workspace.Store.update_members(workspace_name, kept_members) do
      {:ok, _decoded} ->
        Mix.shell().info(
          "  → stripped. workspace://#{workspace_name} now has #{length(kept_members)} member(s)."
        )

      {:error, reason} ->
        Mix.shell().error(
          "  ! Store.update_members/2 failed for workspace://#{workspace_name}: " <>
            "#{inspect(reason)}"
        )
    end
  end
end
