defmodule Mix.Tasks.Ezagent.ExternalMirror.MigrateFeishuBindings do
  @shortdoc "PR-EM-6 one-shot: migrate feishu_session_bindings → external_mirror_bindings"

  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6) — one-shot migration of pre-existing
  `feishu_session_bindings` rows into the generic
  `external_mirror_bindings` projection table + spawn of the matching
  per-binding Worker.

  ## Why direct insert + spawn (not the bind facade)

  `Ezagent.ExternalMirror.bind/4` enforces three checks: Cap 1 (session
  bind cap), Cap 2 (per-adapter allow cap), Cap 3
  (`FeishuAdapter.target_ownership_check/2` — Lark API membership
  query for the caller's open_id). The pre-PR-EM-6 rows were created
  by `mix ezagent.feishu.chat.bind` which bypassed all three: V1
  feishu_session_bindings didn't track a binder, didn't gate on caps,
  and didn't probe Lark membership. Replaying them through the new
  facade would fail Check 3 for the admin caller (admin has no Feishu
  open_id binding) and Check 2 if any binder lacked the Allow cap.

  This task does the equivalent of the bind action body's tail —
  write the projection row + spawn the worker — bypassing the caps
  + ownership gates BECAUSE the operator running `mix ...` is the
  admin authority (no privilege escalation: same admin who could
  grant any cap they want by hand). The post-migration LV-driven
  flow uses the full facade as designed.

  ## What it does

  For each enabled row in `feishu_session_bindings`:

  1. Insert into `external_mirror_bindings` with `adapter_id="feishu"`,
     `target_id=row.chat_id`, `bound_by=<admin or --admin flag>`,
     `bound_at=row.created_at`, `opts_json` carrying the migration
     provenance.
  2. Worker spawn is deferred to the next `mix phx.server` start — at
     application boot `Ezagent.ExternalMirror.BootReconciler` (and the
     Session Kind's `init_slice/1` reconciliation, SPEC §3.1) walk the
     newly-populated `external_mirror_bindings` table and idempotently
     spawn the per-binding Worker. If you run this task against a
     running server's DB AND want immediate publish (without waiting
     for a restart), follow up with `mix ezagent.external_mirror.bind`
     (idempotent — the existing row makes it a no-op success), which
     also triggers the spawn through the live RootSupervisor.
  3. Print a per-row status line + a final summary.

  ## Idempotency

  Safe to re-run. `BindingRow.insert/1` collides on the natural-key
  unique index → mapped to `:already`. Worker spawn returns
  `{:error, {:already_started, _}}` → mapped to success.

  ## Usage

      mix ezagent.external_mirror.migrate_feishu_bindings
      mix ezagent.external_mirror.migrate_feishu_bindings --admin entity://user/system/admin
      mix ezagent.external_mirror.migrate_feishu_bindings --dry-run

  ## Pre-condition

  The `feishu_session_bindings` table must still exist. This task is
  meant to run on the LIVE dev DB before the PR-EM-6 destructive
  schema change drops the table. If the table is already absent, the
  task prints a "nothing to do" message and exits 0.
  """

  use Mix.Task

  require Logger

  alias Ezagent.ExternalMirror.BindingRow

  @adapter_id "feishu"

  @impl Mix.Task
  def run(argv) do
    {opts, _positional, _} =
      OptionParser.parse(argv,
        switches: [admin: :string, dry_run: :boolean, help: :boolean],
        aliases: [h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      :ok
    else
      Mix.Task.run("app.start")

      admin_uri_str = opts[:admin] || "entity://user/system/admin"
      dry_run? = !!opts[:dry_run]

      rows = read_legacy_rows()

      Mix.shell().info(
        "PR-EM-6 migration: found #{length(rows)} feishu_session_bindings row(s) " <>
          "(dry_run=#{dry_run?}, bound_by=#{admin_uri_str})"
      )

      results = Enum.map(rows, &migrate_one(&1, admin_uri_str, dry_run?))
      print_summary(results, dry_run?)
    end
  end

  # ----- read pre-PR-EM-6 rows ----------------------------------------------

  # Direct SQL — `EzagentPluginFeishu.SessionBinding` is deleted in
  # the same commit, so we use a plain query to read its table while
  # the table is still in the schema.
  defp read_legacy_rows do
    sql = """
    SELECT chat_id, session_uri, enabled, created_at
      FROM feishu_session_bindings
     WHERE enabled = 1
     ORDER BY created_at
    """

    try do
      %{rows: rows} = Ecto.Adapters.SQL.query!(EzagentCore.Repo, sql, [])

      Enum.map(rows, fn [chat_id, session_uri, _enabled, created_at] ->
        %{chat_id: chat_id, session_uri: session_uri, created_at: decode_dt(created_at)}
      end)
    rescue
      _ ->
        Mix.shell().info(
          "PR-EM-6 migration: feishu_session_bindings table not present " <>
            "(already dropped, or fresh install). Nothing to migrate."
        )

        []
    end
  end

  defp decode_dt(%DateTime{} = dt), do: dt

  defp decode_dt(bin) when is_binary(bin) do
    case DateTime.from_iso8601(bin) do
      {:ok, dt, _off} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp decode_dt(_), do: DateTime.utc_now()

  # ----- migrate one row ----------------------------------------------------

  defp migrate_one(
         %{chat_id: chat_id, session_uri: session_uri_str, created_at: bound_at},
         admin_uri_str,
         dry_run?
       ) do
    session_uri = Ezagent.URI.parse!(session_uri_str)

    if dry_run? do
      Mix.shell().info("  [dry-run] would bind feishu/#{chat_id} → #{session_uri_str}")
      {:dry_run, chat_id}
    else
      case do_migrate_row(session_uri, chat_id, bound_at, admin_uri_str) do
        :ok ->
          Mix.shell().info("  [ok]      feishu/#{chat_id} → #{session_uri_str}")
          {:ok, chat_id}

        :already ->
          Mix.shell().info("  [already] feishu/#{chat_id} → #{session_uri_str}")
          {:already, chat_id}

        {:error, reason} ->
          Mix.shell().error(
            "  [error]   feishu/#{chat_id} → #{session_uri_str}: #{inspect(reason)}"
          )

          {:error, chat_id, reason}
      end
    end
  end

  defp do_migrate_row(%URI{} = session_uri, chat_id, bound_at, admin_uri_str) do
    workspace_uri = workspace_uri_for(session_uri)
    db_id = BindingRow.row_id(session_uri, @adapter_id, chat_id)

    opts_json =
      Jason.encode!(%{
        "migrated_from" => "feishu_session_bindings",
        "original_bound_at" => DateTime.to_iso8601(bound_at)
      })

    attrs = %{
      id: db_id,
      session_uri: URI.to_string(session_uri),
      adapter_id: @adapter_id,
      target_id: chat_id,
      opts_json: opts_json,
      bound_by: admin_uri_str,
      bound_at: bound_at,
      workspace_uri: workspace_uri
    }

    case BindingRow.insert(attrs) do
      {:ok, _row} ->
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        if unique_constraint_violation?(cs) do
          # Row already exists from a prior migration run — idempotent.
          :already
        else
          {:error, {:db_insert_failed, cs.errors}}
        end

      {:error, other} ->
        {:error, {:db_insert_failed, other}}
    end
  end

  defp workspace_uri_for(session_uri) do
    case Ezagent.Persistence.workspace_uri_for(session_uri) do
      {:ok, ws} when is_binary(ws) ->
        ws

      {:ok, %URI{} = ws} ->
        URI.to_string(ws)

      _ ->
        # SPEC #324 rev 3 (Allen 2026-05-25): no silent workspace
        # fallback. A session_uri that doesn't yield a workspace is a
        # structural bug in the source bindings table — fail loud so
        # the operator fixes the data before running the migration.
        raise ArgumentError,
              "Cannot derive workspace from session_uri=#{inspect(session_uri)}. " <>
                "The source feishu_session_bindings row is structurally invalid; " <>
                "fix the row (or drop it) before re-running the migration. " <>
                "Per SPEC #324, no silent fallback to any workspace is allowed."
    end
  end

  defp unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # ----- summary ------------------------------------------------------------

  defp print_summary(results, dry_run?) do
    ok = Enum.count(results, &match?({:ok, _}, &1))
    already = Enum.count(results, &match?({:already, _}, &1))
    errors = Enum.count(results, &match?({:error, _, _}, &1))
    dryrun = Enum.count(results, &match?({:dry_run, _}, &1))

    Mix.shell().info("")

    Mix.shell().info(
      "PR-EM-6 migration summary: ok=#{ok} already=#{already} dry_run=#{dryrun} " <>
        "errors=#{errors} (total=#{length(results)})"
    )

    cond do
      dry_run? ->
        Mix.shell().info("(no rows written — re-run without --dry-run to apply)")

      errors > 0 ->
        Mix.shell().error(
          "Some rows failed. Inspect the [error] lines above. Already-migrated " <>
            "rows are skipped on re-run."
        )

      true ->
        Mix.shell().info("All rows migrated.")
    end

    :ok
  end
end
