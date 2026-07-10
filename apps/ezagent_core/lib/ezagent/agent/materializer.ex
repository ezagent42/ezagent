defmodule Ezagent.Agent.Materializer do
  @moduledoc """
  #17 agent-provisioning-cascade **PR-2** — the flavor-generic config_dir materializer
  primitives (spec §7, §D4.1, §D4.2, §D6, §5.1). Lives in `ezagent_core` so the cc and
  codex Template Classes (and any future file-flavor) DELEGATE to one shared, isolated,
  unit-testable implementation rather than each re-hand-rolling the replace/merge/secret
  logic (North Star — keep plugin authors out of the security-critical core).

  It owns four disjoint concerns, each independently testable:

    * `atomic_replace/3` (spec §7) — **atomic-replace-with-rollback**. The PR-B
      materializer did `File.rm_rf(target)` THEN `File.rename(staging, target)`; a crash
      between the two leaves the agent with **no** config_dir. This replaces it with a
      real replace protocol: move the current target ASIDE to a sibling `.bak`, rename
      the staging dir into place, drop the `.bak` on success / RESTORE it on any failure.
      A failed materialization therefore leaves the PRIOR good config_dir intact — never
      an empty or half-merged dir. A `:fail_after_move` injection hook makes the
      crash-after-move window directly testable. A failed ROLLBACK is no longer swallowed:
      `atomic_replace/3` returns `{:error, {:atomic_replace_rollback_failed, ...}}` when the
      prior config could not be restored, and `recover_orphaned/1` self-heals a leftover
      `.bak` + missing/partial target at the next (re)spawn so a crash mid-swap is RECOVERABLE.

    * `merge_layers/2` (spec §D4.1 + §D4.2) — merge the ordered low→high layer set into a
      staging dir: **whole-file-replace** for same-path config files (higher layer wins),
      **directory-union with trust-aware tombstones** for collection dirs (a higher layer
      may remove an inherited file via a `<name>.tombstone` marker UNLESS the relpath is
      in a lower layer's `protected` set and the removing layer lacks the management cap),
      and a **mandatory-set post-merge validation** (a higher layer must not drop a
      lower-layer security control by replacing-to-omit it).

    * `copy_secret_relpaths/3` (spec §D6) — copy ONLY the flavor's `secret_relpaths`
      (pure token material) FROM the resolved credential source's config_dir INTO the
      staging dir. Never the whole source dir, never config paths.

    * `materialize_with_grant/2` (spec §5.1) — the **TOCTOU-safe leased** wrapper around
      a secret copy + commit: `fetch_for_materialize` the grant, copy the secret under the
      grant-scoped read, then `revalidate_version!` immediately before the commit/exec
      callback runs. If the grant changed (revoked mid-start) the start is ABORTED and the
      atomic-replace rolls back — no process is launched holding a revoked secret.

  Everything here is pure file/data logic + the PR-0 grant store; it does NO dispatch, NO
  process spawning, NO subprocess exec (the flavor owns "exec" via a callback).
  """

  alias Ezagent.Credential.GrantRow

  require Logger

  # ── atomic-replace-with-rollback (spec §7) ─────────────────────────────────

  @typedoc """
  Options for `atomic_replace/3`:

    * `:fail_after_move` — TEST-ONLY failure injection. When `true`, simulate a
      crash/failure AFTER the target has been moved aside to `.bak` and (optionally)
      BEFORE/AROUND the staging rename, exercising the rollback path. The prior good
      target MUST be restored intact.
    * `:on_fail_after_move` — TEST-ONLY 0-arity fn run when `:fail_after_move` fires,
      AFTER the move-aside but BEFORE the rollback, to plant a partial/un-clearable
      `target` (simulating a half-completed rename). Lets a test exercise the
      restore-FAILURE path where rollback cannot put the prior tree back.
  """
  @type replace_opt :: {:fail_after_move, boolean()} | {:on_fail_after_move, (-> any())}

  @doc """
  Atomically replace `target` with the fully-built `staging` dir, rolling back to the
  PRIOR `target` on any failure (spec §7).

  Protocol:

    1. ensure `target`'s parent exists;
    2. if `target` exists, move it ASIDE to a unique sibling `<target>.bak-<n>`;
    3. `File.rename(staging, target)` (atomic on the same filesystem — staging is a
       sibling);
    4. on success → drop the `.bak`; on ANY failure → restore the `.bak` back to
       `target` (and drop the now-orphaned staging).

  At no point is `target` left absent across a crash window that we control: the only
  moment `target` does not exist is the instant between the move-aside and the rename,
  and a failure there restores `.bak`. The caller stages into a sibling and passes it
  here as the FINAL step of materialization.

  Returns `{:ok, target}` or `{:error, reason}` (with the prior target restored).
  """
  @spec atomic_replace(String.t(), String.t(), [replace_opt()]) ::
          {:ok, String.t()} | {:error, term()}
  def atomic_replace(staging, target, opts \\ [])
      when is_binary(staging) and is_binary(target) do
    bak = bak_path(target)
    had_target? = File.exists?(target)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- move_aside(target, bak, had_target?),
         :ok <- inject_failure(opts),
         :ok <- File.rename(staging, target) do
      # Success — the new tree is in place; drop the saved prior tree.
      _ = if had_target?, do: File.rm_rf(bak)
      {:ok, target}
    else
      {:error, reason} ->
        # Roll back: restore the prior target (if any), drop the orphaned staging.
        # `restore_aside` now PROPAGATES a restore failure (codex H3' fix): if the prior
        # config could NOT be put back, the caller must NOT claim success — the error
        # carries both the original failure AND the rollback failure so the operator knows
        # rollback failed (the `.bak` is left on disk for `recover_orphaned/1` to retry).
        _ = File.rm_rf(staging)

        case restore_aside(bak, target, had_target?) do
          :ok ->
            {:error, {:atomic_replace_failed, reason}}

          {:error, restore_reason} ->
            {:error,
             {:atomic_replace_rollback_failed, original: reason, rollback: restore_reason}}
        end
    end
  end

  @bak_infix ".bak-"
  @config_complete_marker ".ezagent-config-complete"

  # The sibling `.bak` path for a target's move-aside. A single, recognizable infix lets
  # `recover_orphaned/1` find a leftover `.bak` after a crash mid-swap.
  defp bak_path(target), do: "#{target}#{@bak_infix}#{System.unique_integer([:positive])}"

  @doc """
  Startup recovery for an `atomic_replace/3` crash-mid-swap (codex H3' (b)).

  `atomic_replace/3` moves the prior `target` aside to a sibling `<target>.bak-<n>` and then
  renames staging into place. If the VM/host dies in the window AFTER the move-aside and
  BEFORE/DURING the rename, the next spawn would find `target` missing (or partially
  written) while the known-good prior tree sits in the orphaned `.bak`. Without recovery
  the agent is left with a permanently-absent config_dir.

  Call this at agent (re)spawn / materialize ENTRY for the canonical `target`. It scans the
  parent dir for `<basename>.bak-*` siblings of `target`:

    * if `target` is MISSING or lacks the completion marker and a `.bak` exists → RESTORE
      the newest `.bak` back to `target` (self-heal the crash-mid-swap), then drop any
      older `.bak`s;
    * if `target` is PRESENT with the completion marker → the swap completed (or never
      started); the `.bak`(s) are stale leftovers → drop them all;
    * if no `.bak` exists → nothing to do.

  Best-effort + idempotent: returns `:ok` when there was nothing to recover or recovery
  succeeded, `{:recovered, bak}` when it restored a `.bak`, or `{:error, reason}` if a
  detected recovery could NOT be performed (caller decides whether to proceed).
  """
  @spec recover_orphaned(String.t()) :: :ok | {:recovered, String.t()} | {:error, term()}
  def recover_orphaned(target) when is_binary(target) do
    case orphan_baks(target) do
      [] ->
        :ok

      baks ->
        # newest first (highest unique-integer suffix sorts last lexically only for equal
        # widths, so sort by mtime to be safe).
        [newest | older] = Enum.sort_by(baks, &bak_mtime/1, :desc)

        result =
          if target_usable?(target) do
            # Swap completed (or never moved aside) — every `.bak` is a stale leftover.
            :ok
          else
            # Crash mid-swap: target absent/partial. Restore the newest known-good `.bak`.
            _ = File.rm_rf(target)

            case File.rename(newest, target) do
              :ok -> {:recovered, target}
              {:error, reason} -> {:error, {:recover_restore_failed, newest, reason}}
            end
          end

        # Drop ONLY the `.bak`s we have confirmed are no longer needed (codex H —
        # recover_orphaned restore-failure):
        #
        #   * `{:recovered, _}` — the newest was renamed into the now-good target; only the
        #     `older` set is stale → drop them.
        #   * `:ok` (target already usable / committed) — every `.bak` is a stale leftover →
        #     drop them all.
        #   * `{:error, _}` (restore FAILED) — the selected `.bak` is the ONLY known-good
        #     copy of the prior config. DROP NOTHING (not even `older`); leaving the full set
        #     lets the operator / a retried `recover_orphaned/1` self-heal. Dropping the
        #     newest here would leave the agent with NO target AND NO recoverable backup.
        to_drop =
          case result do
            {:recovered, _} -> older
            :ok -> [newest | older]
            {:error, _} -> []
          end

        Enum.each(to_drop, &File.rm_rf/1)

        result
    end
  end

  # `target` is usable only when it carries the same completion marker written by the
  # flavor `stage_and_swap` helpers. A non-empty markerless target is still a partial
  # crash artifact and must not cause the known-good `.bak` to be dropped.
  defp target_usable?(target) do
    File.dir?(target) and File.exists?(Path.join(target, @config_complete_marker))
  end

  defp orphan_baks(target) do
    parent = Path.dirname(target)
    prefix = Path.basename(target) <> @bak_infix

    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&Path.join(parent, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  defp bak_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> 0
    end
  end

  # Move the current target out of the way. If there was no prior target, nothing to do
  # (the rename below creates it fresh).
  defp move_aside(_target, _bak, false), do: :ok

  defp move_aside(target, bak, true) do
    case File.rename(target, bak) do
      :ok -> :ok
      {:error, reason} -> {:error, {:move_aside_failed, reason}}
    end
  end

  # Restore the prior target from the .bak (rollback). If there was no prior target we
  # ensure the partial new target (if the rename half-happened) is removed so we never
  # leave a half-merged dir. Returns `:ok` on a clean rollback or `{:error, reason}` when
  # the prior config could NOT be restored (codex H3' — restore failures are no longer
  # swallowed; the caller surfaces them so it never claims success on a failed rollback).
  defp restore_aside(_bak, target, false) do
    case File.rm_rf(target) do
      {:ok, _} -> :ok
      {:error, reason, path} -> {:error, {:partial_target_cleanup_failed, path, reason}}
    end
  end

  defp restore_aside(bak, target, true) do
    if File.exists?(bak) do
      # The bak is the known-good prior tree. Clear any partial new target, then move
      # the prior tree back into place. Each step's failure is surfaced — a left-behind
      # partial target or a failed rename means the prior config is NOT restored.
      with {:ok, _} <- File.rm_rf(target),
           :ok <- File.rename(bak, target) do
        :ok
      else
        {:error, reason, path} -> {:error, {:rollback_partial_cleanup_failed, path, reason}}
        {:error, reason} -> {:error, {:rollback_restore_failed, reason}}
      end
    else
      # bak was already consumed (rename succeeded then a later step failed) — the new
      # target IS in place; nothing to restore. (Current protocol has no post-rename
      # step, but keep the branch honest for future extension.)
      :ok
    end
  end

  defp inject_failure(opts) do
    if Keyword.get(opts, :fail_after_move, false) do
      case Keyword.get(opts, :on_fail_after_move) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end

      {:error, :injected_failure_after_move}
    else
      :ok
    end
  end

  # ── layer merge (spec §D4.1 whole-file-replace + §D4.2 directory-union) ─────

  @typedoc """
  A single config layer for the merge (spec §D2 ordering: layers are passed low→high).

    * `:dir` — the layer's source directory on disk (the layer's contribution);
    * `:protected` — relpaths this layer declares as PROTECTED security controls
      (spec §D4.2): a higher layer cannot tombstone them without the management cap;
    * `:mandatory` — relpaths this layer declares as MANDATORY (spec §D4.1 G1): they
      MUST be present + intact in the final merged tree (post-merge validation);
    * `:mgmt_cap?` — does THIS layer hold the management cap (may it remove a lower
      layer's protected path?). Defaults `false`.
  """
  @type layer :: %{
          required(:dir) => String.t(),
          optional(:protected) => [String.t()],
          optional(:mandatory) => [String.t()],
          optional(:mgmt_cap?) => boolean()
        }

  @tombstone_suffix ".tombstone"

  @doc """
  Merge the ordered low→high `layers` into the empty `staging` dir (spec §D4).

  For each layer in order, its files are unioned/overwritten on top of the accumulated
  staging tree (whole-file-replace per §D4.1; directory-union per §D4.2). A
  `<relpath>.tombstone` marker in a layer removes `<relpath>` from the merged tree —
  trust-gated per §D4.2: a tombstone targeting a relpath PROTECTED by a lower layer, or
  an ancestor of one, is REJECTED unless the tombstoning layer holds the management cap.

  After all layers are applied, the **mandatory set** (union of every layer's
  `:mandatory`) is validated present in the staging tree (spec §D4.1 G1). A missing
  mandatory control → `{:error, {:mandatory_control_missing, relpath}}` (fail loud).

  Returns `:ok` (staging now holds the merged tree) or `{:error, reason}`.
  """
  @spec merge_layers(String.t(), [layer()]) :: :ok | {:error, term()}
  def merge_layers(staging, layers) when is_binary(staging) and is_list(layers) do
    with :ok <- File.mkdir_p(staging),
         {:ok, protected_acc, mandatory_acc} <- apply_layers(staging, layers),
         :ok <- validate_mandatory(staging, mandatory_acc) do
      _ = protected_acc
      :ok
    end
  end

  # Fold the layers low→high, accumulating the protected set (so a higher layer's
  # tombstone is checked against ALL lower layers' protected paths) and the mandatory set.
  defp apply_layers(staging, layers) do
    Enum.reduce_while(layers, {:ok, MapSet.new(), MapSet.new()}, fn layer,
                                                                    {:ok, protected_acc,
                                                                     mandatory_acc} ->
      dir = Map.get(layer, :dir)

      cond do
        is_nil(dir) ->
          # An absent layer (no contribution) — still folds its declarations forward.
          {:cont, {:ok, protected_acc, fold_mandatory(layer, mandatory_acc)}}

        not File.dir?(dir) ->
          {:halt, {:error, {:layer_dir_missing, dir}}}

        true ->
          case apply_one_layer(staging, dir, layer, protected_acc) do
            :ok ->
              next_protected = fold_protected(layer, protected_acc)
              next_mandatory = fold_mandatory(layer, mandatory_acc)
              {:cont, {:ok, next_protected, next_mandatory}}

            {:error, _} = err ->
              {:halt, err}
          end
      end
    end)
  end

  defp fold_protected(layer, acc),
    do: MapSet.union(acc, MapSet.new(Map.get(layer, :protected, [])))

  defp fold_mandatory(layer, acc),
    do: MapSet.union(acc, MapSet.new(Map.get(layer, :mandatory, [])))

  # Apply ONE layer's contribution onto the accumulated staging tree. Two passes:
  #  1. tombstones — for every `<rel>.tombstone` in the layer, REMOVE `<rel>` from
  #     staging (trust-gated against `protected_acc`, including protected descendants).
  #  2. union/overwrite — copy every non-tombstone file from the layer into staging
  #     (higher layer wins on collision).
  defp apply_one_layer(staging, dir, layer, protected_acc) do
    tombstone_targets = tombstone_targets(dir)

    with :ok <- apply_tombstones(staging, layer, protected_acc, tombstone_targets) do
      copy_layer_files(staging, dir, tombstone_targets)
    end
  end

  defp tombstone_targets(dir) do
    dir
    |> list_relpaths()
    |> Enum.filter(&String.ends_with?(&1, @tombstone_suffix))
    |> Enum.map(&String.replace_suffix(&1, @tombstone_suffix, ""))
  end

  defp apply_tombstones(staging, layer, protected_acc, tombstone_targets) do
    mgmt? = Map.get(layer, :mgmt_cap?, false)

    Enum.reduce_while(tombstone_targets, :ok, fn target_rel, :ok ->
      cond do
        # §D4.2 trust gate: removing a protected lower-layer path, or an ancestor of one,
        # needs the mgmt cap.
        protected_tombstone?(protected_acc, target_rel) and not mgmt? ->
          {:halt, {:error, {:protected_tombstone_denied, target_rel}}}

        true ->
          _ = File.rm_rf(Path.join(staging, target_rel))
          {:cont, :ok}
      end
    end)
  end

  defp copy_layer_files(staging, dir, tombstone_targets) do
    dir
    |> list_relpaths()
    |> Enum.reject(&String.ends_with?(&1, @tombstone_suffix))
    |> Enum.reject(&tombstoned_by_layer?(&1, tombstone_targets))
    |> Enum.reduce_while(:ok, fn rel, :ok ->
      case copy_one(Path.join(dir, rel), Path.join(staging, rel)) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp protected_tombstone?(protected_acc, target_rel) do
    Enum.any?(protected_acc, fn protected_rel ->
      same_or_ancestor_rel?(target_rel, protected_rel)
    end)
  end

  defp tombstoned_by_layer?(rel, tombstone_targets) do
    Enum.any?(tombstone_targets, &same_or_ancestor_rel?(&1, rel))
  end

  defp same_or_ancestor_rel?(candidate, rel) do
    candidate_parts = Path.split(candidate)
    rel_parts = Path.split(rel)
    candidate_parts == Enum.take(rel_parts, length(candidate_parts))
  end

  defp validate_mandatory(staging, mandatory_set) do
    Enum.reduce_while(mandatory_set, :ok, fn rel, :ok ->
      if File.exists?(Path.join(staging, rel)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:mandatory_control_missing, rel}}}
      end
    end)
  end

  # ── secret-only copy (spec §D6) ────────────────────────────────────────────

  @doc """
  Copy ONLY `secret_relpaths` (pure token material) from the resolved credential
  `source_dir` into `staging` (spec §D6). NEVER the whole source dir, NEVER config paths.
  A missing secret file at the source is tolerated (the source may not be logged in yet —
  the flavor's own auth-failure detection handles that at runtime); a copy ERROR fails
  loud. Secret files are chmod-ed 0600.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec copy_secret_relpaths(String.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def copy_secret_relpaths(source_dir, staging, secret_relpaths)
      when is_binary(source_dir) and is_binary(staging) and is_list(secret_relpaths) do
    Enum.reduce_while(secret_relpaths, :ok, fn rel, :ok ->
      src = Path.join(source_dir, rel)
      dest = Path.join(staging, rel)

      cond do
        not File.exists?(src) ->
          # Source has no such secret yet (not logged in) — leave staging without it.
          {:cont, :ok}

        true ->
          with :ok <- File.mkdir_p(Path.dirname(dest)),
               :ok <- copy_one(src, dest),
               :ok <- File.chmod(dest, 0o600) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {:secret_copy_failed, rel, reason}}}
          end
      end
    end)
  end

  # ── TOCTOU-safe leased materialization (spec §5.1) ─────────────────────────

  @typedoc """
  Inputs for `materialize_with_grant/2`:

    * `:agent_uri` — the agent being materialized (string; keys the grant);
    * `:staging` — the already layer-merged staging dir (secrets get copied INTO it);
    * `:secret_relpaths` — the flavor's secret files (spec §D6);
    * `:source_dir_for` — `(source_uri :: String.t() -> {:ok, dir} | {:error, reason})`
      resolves the grant's credential source URI to its on-disk config_dir under the
      grant-scoped read (the §5.1 grant-scoped principal). Injected so core does no
      dispatch.
    * `:commit` — `(version :: non_neg_integer() -> {:ok, term} | {:error, term})` the
      FINAL config-swap step (atomic-replace). Called ONLY after the TOCTOU re-check
      passes. Receives the grant `version` validated at materialize so the caller can
      thread it to a SECOND re-validation immediately before the (later) subprocess launch
      — the swap and the launch are separate boundaries (codex CRITICAL §5.1).
  """
  @type grant_inputs :: %{
          required(:agent_uri) => String.t(),
          required(:staging) => String.t(),
          required(:secret_relpaths) => [String.t()],
          required(:source_dir_for) => (String.t() -> {:ok, String.t()} | {:error, term()}),
          required(:commit) => (non_neg_integer() -> {:ok, term()} | {:error, term()})
        }

  @doc """
  Spec §5.1 — TOCTOU-safe leased secret materialization + commit.

  Sequence (every step fail-loud):

    1. `GrantRow.fetch_for_materialize(agent_uri)` → `{source_uri, version}` (active,
       non-revoked, scope still matches, source exists). Any failure → abort (no
       launch with stale/leaked creds).
    2. resolve `source_uri` → on-disk dir via `source_dir_for` (grant-scoped read).
    3. `copy_secret_relpaths` from that dir into `staging`.
    4. `GrantRow.revalidate_version!(agent_uri, version)` — re-check the version
       IMMEDIATELY before commit. If it changed (revoked mid-start) → `{:error,
       :grant_changed}`, do NOT commit/exec.
    5. `commit.(version)` — the atomic-replace config swap (NOT the subprocess launch). The
       validated `version` is handed to the commit so the caller can thread it to a SECOND
       `revalidate_version!/2` immediately before the LATER subprocess launch (the swap and
       the launch are distinct boundaries — codex CRITICAL §5.1).

  Returns the `commit` result `{:ok, term}` or `{:error, reason}`.
  """
  @spec materialize_with_grant(grant_inputs(), keyword()) :: {:ok, term()} | {:error, term()}
  def materialize_with_grant(%{agent_uri: agent_uri} = inputs, _opts \\ [])
      when is_binary(agent_uri) do
    staging = Map.fetch!(inputs, :staging)
    secret_relpaths = Map.fetch!(inputs, :secret_relpaths)
    source_dir_for = Map.fetch!(inputs, :source_dir_for)
    commit = Map.fetch!(inputs, :commit)

    with {:ok, source_uri, version} <- GrantRow.fetch_for_materialize(agent_uri),
         {:ok, source_dir} <- source_dir_for.(source_uri),
         :ok <- copy_secret_relpaths(source_dir, staging, secret_relpaths),
         :ok <- warn_if_no_secret_landed(agent_uri, source_uri, staging, secret_relpaths),
         :ok <- GrantRow.revalidate_version!(agent_uri, version),
         {:ok, result} <- commit.(version) do
      {:ok, result}
    end
  end

  # Loud-but-non-fatal (chain B / #1096 credential gap). The #17 grant gate
  # ALLOWED this credential source, but `copy_secret_relpaths/3` is best-effort:
  # when the source identity is not logged in it carries none of the flavor's
  # secrets and silently leaves the staging without them. That is not a fault
  # HERE (a not-yet-logged-in source is legitimate; the materialize completes),
  # but the launch gate `Ezagent.Credential.HomeRuntime.config_dir_launchable?/2`
  # will refuse the resulting credential-less home. Surface WHY the credential is
  # missing at the source (telemetry + info) so it is not a silent no-op that
  # only shows up later as an opaque "Not logged in" (exit-256). NEVER copies a
  # host login here — that stays gated by `HostLoginAdopt` (#161 co-tenant
  # isolation).
  defp warn_if_no_secret_landed(_agent_uri, _source_uri, _staging, []), do: :ok

  defp warn_if_no_secret_landed(agent_uri, source_uri, staging, secret_relpaths) do
    if Enum.any?(secret_relpaths, &File.exists?(Path.join(staging, &1))) do
      :ok
    else
      :telemetry.execute(
        [:ezagent, :credential, :source_missing_secret],
        %{count: 1},
        %{agent_uri: agent_uri, source_uri: source_uri}
      )

      Logger.info(
        "credential source #{inspect(source_uri)} for agent #{agent_uri} carried none of " <>
          "#{inspect(secret_relpaths)} — the materialized home will be non-launchable until " <>
          "the source logs in (chain B / #1096)"
      )

      :ok
    end
  end

  # ── shared helpers ─────────────────────────────────────────────────────────

  # All relpaths (files + symlinks, NOT dirs) under `dir`, recursively. Dirs are implied
  # by their files (created via mkdir_p on copy). Symlinks are rejected up-front by the
  # callers' flavor materializers (spec D3); here we copy them as regular files if present.
  defp list_relpaths(dir) do
    dir
    |> walk("")
    |> Enum.sort()
  end

  defp walk(dir, prefix) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)
          rel = if prefix == "", do: entry, else: Path.join(prefix, entry)

          if File.dir?(full) do
            walk(full, rel)
          else
            [rel]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp copy_one(src, dest) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _} <- File.copy(src, dest) do
      :ok
    else
      {:error, reason} -> {:error, {:copy_failed, src, reason}}
    end
  end
end
