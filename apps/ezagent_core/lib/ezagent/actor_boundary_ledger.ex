defmodule Ezagent.ActorBoundaryLedger do
  @moduledoc """
  Frozen SITE fingerprints for the actor-boundary gate (`Ezagent.ActorBoundaryScanner`).

  The census DATA lives in the sibling `actor_boundary_ledger.exs` (a plain data
  file, NOT a compiled module — kept out of the oversized-module `.ex` count). It
  is loaded from the source tree at RUNTIME (dev/CI only; this is a static-analysis
  gate, never a shipped runtime asset) and memoized in `:persistent_term`. Each
  entry is `%{path, target, sha, note}` where `sha` is SHA-256 of the trimmed
  offending source line.

  The ratchet enforces `scanned − ledger == []` (a new site REDs) and
  `ledger − scanned == []` (stale entries must be removed — the ledger only
  shrinks). Seeded from the C0 empty-allowlist enumerator run.

  - `forward_ratchet/0` — the §4.4 reach-in census (migrates onto the §2.2 read
    surface across C1–C5; get_slice/get_raw_slice ratchet→C7).
  - `forward_fixed/0` — the permanent process-generation consumers that SURVIVE
    C4 (cap.ex, entity/token.ex); authorize.ex is C4 debt in `forward_ratchet/0`.
  - `reverse_ratchet/0` — the §3.4 port worklist (mover-set upward refs; C5).
  - `reverse_fixed/0` — the one reasoned reverse carve-out (LegacyCallbacks
    quoted Ezagent.Capability.cap/3).
  """

  @rel_path "apps/ezagent_core/lib/ezagent/actor_boundary_ledger.exs"

  @doc false
  def forward_ratchet, do: data().forward_ratchet
  @doc false
  def forward_fixed, do: data().forward_fixed
  @doc false
  def reverse_ratchet, do: data().reverse_ratchet
  @doc false
  def reverse_fixed, do: data().reverse_fixed

  defp data do
    case :persistent_term.get({__MODULE__, :data}, nil) do
      nil ->
        {loaded, _} =
          Code.eval_file(Path.join(Ezagent.ActorBoundaryScanner.repo_root(), @rel_path))

        :persistent_term.put({__MODULE__, :data}, loaded)
        loaded

      loaded ->
        loaded
    end
  end
end
