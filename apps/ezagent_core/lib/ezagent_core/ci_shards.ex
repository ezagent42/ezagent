defmodule EzagentCore.CiShards do
  @moduledoc """
  Shard manifest + assignment for the CI full-suite split.

  The full-suite (`mix ci.local`) runs the whole ~1069-file umbrella `mix test`
  as ONE monolith. This module splits that test step into named shards so a red
  isolates to ONE shard and can be re-run alone (see `mix ci.shard.<name>` in
  `mix.exs` and the `.github/workflows/ci.yml` full-suite matrix).

  The rules live in the single-source `ci_shards.exs` at the umbrella root
  (baked in at compile time via `@external_resource`). Every umbrella test file
  is assigned to EXACTLY ONE shard by first-match-wins (`assign/1`); the
  `verify/0` enumerator proves the assignment covers every file (empty-allowlist
  — 0 unassigned), which `mix ci.shard.verify` and the `ci_shard_parity_test`
  arch gate enforce. A shard split that silently drops a test file is worse than
  the monolith, so parity is a HARD gate, not a convention.
  """

  # `ci_shards.exs` is a CI/dev manifest read ONCE at COMPILE time (baked below
  # via @external_resource + Code.eval_file) — NOT a shipped runtime asset, so it
  # is outside the DirRelativeRuntimeAsset invariant (which targets `__DIR__`-based
  # SHIPPED-asset resolution). Anchored on the compile-time source path via
  # `__ENV__.file` rather than an arch-allow'd `__DIR__`: `mix format` relocates an
  # inline `# arch-allow:` off any module-attribute line, so the same-line
  # suppression can't be kept stable here.
  @shards_file Path.expand("../../../../ci_shards.exs", Path.dirname(__ENV__.file))
  @external_resource @shards_file
  @test_shards @shards_file |> Code.eval_file() |> elem(0) |> Map.fetch!(:test_shards)

  @doc "Ordered test-shard names, in first-match order (e.g. `[\"e2e\", \"core\", ...]`)."
  @spec shard_names() :: [String.t()]
  def shard_names, do: Enum.map(@test_shards, fn {name, _pats} -> name end)

  @doc "The raw `{name, patterns}` rules (first-match order)."
  @spec rules() :: [{String.t(), [String.t()]}]
  def rules, do: @test_shards

  @doc """
  Umbrella root. Works whether the caller's cwd is the umbrella root (CI /
  `gate.arch`) or a child app dir (standalone `cd apps/foo && mix test`) — mirrors
  the `Mix.Tasks.Ezagent.Arch.Scan` root-discovery pattern.
  """
  @spec repo_root() :: String.t()
  def repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  @doc """
  Every umbrella test file (umbrella-root-relative, sorted). This is the exact
  set the monolith `mix test` runs — the denominator of the parity proof.
  """
  @spec all_test_files() :: [String.t()]
  def all_test_files do
    root = repo_root()

    Path.wildcard(Path.join(root, "apps/*/test/**/*_test.exs"))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  @doc """
  Shard a single file is assigned to (first-match-wins), or `:unassigned` if it
  matches no rule. `path` is umbrella-root-relative.
  """
  @spec assign(String.t()) :: String.t() | :unassigned
  def assign(path) do
    Enum.find_value(@test_shards, :unassigned, fn {name, pats} ->
      if Enum.any?(pats, &String.contains?(path, &1)), do: name, else: false
    end)
  end

  @doc "The test files assigned to shard `name` (what `mix ci.shard.<name>` runs)."
  @spec files_for(String.t()) :: [String.t()]
  def files_for(name), do: all_test_files() |> Enum.filter(&(assign(&1) == name))

  @doc """
  Parity report over the full test-file set:

    * `:total`      — number of test files the monolith runs
    * `:counts`     — files per shard
    * `:unassigned` — files matching NO shard rule (MUST be empty)
    * `:empty`      — shard names that matched zero files (a rule went stale)
    * `:ok?`        — `true` iff `unassigned == []` and no shard is empty
  """
  @spec verify() :: %{
          total: non_neg_integer(),
          counts: %{optional(String.t()) => non_neg_integer()},
          unassigned: [String.t()],
          empty: [String.t()],
          ok?: boolean()
        }
  def verify do
    files = all_test_files()
    grouped = Enum.group_by(files, &assign/1)
    unassigned = Map.get(grouped, :unassigned, [])
    counts = Map.new(shard_names(), fn n -> {n, length(Map.get(grouped, n, []))} end)
    empty = for {n, 0} <- counts, do: n

    %{
      total: length(files),
      counts: counts,
      unassigned: unassigned,
      empty: empty,
      ok?: unassigned == [] and empty == []
    }
  end
end
