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
      crash-after-move window directly testable.

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
  """
  @type replace_opt :: {:fail_after_move, boolean()}

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
    bak = "#{target}.bak-#{System.unique_integer([:positive])}"
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
        restore_aside(bak, target, had_target?)
        _ = File.rm_rf(staging)
        {:error, {:atomic_replace_failed, reason}}
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
  # leave a half-merged dir.
  defp restore_aside(_bak, target, false) do
    _ = File.rm_rf(target)
    :ok
  end

  defp restore_aside(bak, target, true) do
    if File.exists?(bak) do
      # The bak is the known-good prior tree. Clear any partial new target, then move
      # the prior tree back into place.
      _ = File.rm_rf(target)
      _ = File.rename(bak, target)
      :ok
    else
      # bak was already consumed (rename succeeded then a later step failed) — the new
      # target IS in place; nothing to restore. (Current protocol has no post-rename
      # step, but keep the branch honest for future extension.)
      :ok
    end
  end

  defp inject_failure(opts) do
    if Keyword.get(opts, :fail_after_move, false) do
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
  trust-gated per §D4.2: a tombstone targeting a relpath PROTECTED by a lower layer is
  REJECTED unless the tombstoning layer holds the management cap.

  After all layers are applied, the **mandatory set** (union of every layer's
  `:mandatory`) is validated present in the staging tree (spec §D4.1 G1). A missing
  mandatory control → `{:error, {:mandatory_control_missing, relpath}}` (fail loud).

  Returns `:ok` (staging now holds the merged tree) or `{:error, reason}`.
  """
  @spec merge_layers(String.t(), [layer()]) :: :ok | {:error, term()}
  def merge_layers(staging, layers) when is_binary(staging) and is_list(layers) do
    with :ok <- File.mkdir_p(staging),
         {:ok, protected_acc, mandatory_acc} <- apply_layers(staging, layers),
         :ok <- strip_tombstone_markers(staging),
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
  #     staging (trust-gated against `protected_acc`).
  #  2. union/overwrite — copy every non-tombstone file from the layer into staging
  #     (higher layer wins on collision).
  defp apply_one_layer(staging, dir, layer, protected_acc) do
    with :ok <- apply_tombstones(staging, dir, layer, protected_acc) do
      copy_layer_files(staging, dir)
    end
  end

  defp apply_tombstones(staging, dir, layer, protected_acc) do
    mgmt? = Map.get(layer, :mgmt_cap?, false)

    dir
    |> list_relpaths()
    |> Enum.filter(&String.ends_with?(&1, @tombstone_suffix))
    |> Enum.reduce_while(:ok, fn tombstone_rel, :ok ->
      target_rel = String.replace_suffix(tombstone_rel, @tombstone_suffix, "")

      cond do
        # §D4.2 trust gate: removing a protected lower-layer path needs the mgmt cap.
        MapSet.member?(protected_acc, target_rel) and not mgmt? ->
          {:halt, {:error, {:protected_tombstone_denied, target_rel}}}

        true ->
          _ = File.rm_rf(Path.join(staging, target_rel))
          # Carry the tombstone marker itself into staging so a later (higher) layer's
          # union doesn't accidentally undo the removal by re-copying the base file; the
          # markers are stripped at the end (`strip_tombstone_markers/1`).
          case copy_one(Path.join(dir, tombstone_rel), Path.join(staging, tombstone_rel)) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp copy_layer_files(staging, dir) do
    dir
    |> list_relpaths()
    |> Enum.reject(&String.ends_with?(&1, @tombstone_suffix))
    |> Enum.reduce_while(:ok, fn rel, :ok ->
      case copy_one(Path.join(dir, rel), Path.join(staging, rel)) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # After merging, delete every tombstone marker so they never reach the agent's tree
  # AND re-apply the removal (a higher layer may have re-introduced the base file via its
  # union pass — the tombstone wins on a same-layer-or-lower target).
  defp strip_tombstone_markers(staging) do
    staging
    |> list_relpaths()
    |> Enum.filter(&String.ends_with?(&1, @tombstone_suffix))
    |> Enum.each(fn tombstone_rel ->
      target_rel = String.replace_suffix(tombstone_rel, @tombstone_suffix, "")
      _ = File.rm_rf(Path.join(staging, target_rel))
      _ = File.rm_rf(Path.join(staging, tombstone_rel))
    end)

    :ok
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
    * `:commit` — `(-> {:ok, term} | {:error, term})` the FINAL commit/exec step
      (atomic-replace + subprocess launch). Called ONLY after the TOCTOU re-check passes.
  """
  @type grant_inputs :: %{
          required(:agent_uri) => String.t(),
          required(:staging) => String.t(),
          required(:secret_relpaths) => [String.t()],
          required(:source_dir_for) => (String.t() -> {:ok, String.t()} | {:error, term()}),
          required(:commit) => (-> {:ok, term()} | {:error, term()})
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
    5. `commit.()` — the atomic-replace + exec.

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
         :ok <- GrantRow.revalidate_version!(agent_uri, version),
         {:ok, result} <- commit.() do
      {:ok, result}
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
