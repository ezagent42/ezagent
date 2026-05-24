defmodule Mix.Tasks.Ezagent.Snapshot.Clear do
  @shortdoc "Delete a Kind snapshot row (next spawn → init_fresh)"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (DB maintenance).**
  > Intentionally NOT a dispatched op. Operates on stored snapshot
  > rows so that the next spawn does init_fresh — useful for resetting
  > a Kind that has wedged state. The audit (Finding 2 carve-out +
  > Section 5 Finding 5) flags `snapshot.clear` as "should arguably be
  > a Behavior so caps gate it" — TODO defer until a `system://snapshots`
  > Kind is introduced. For now stays as `mix ezagent.*`; do NOT
  > migrate to `mix esr`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Snapshots row) + Finding 5.

  Phase 5 PR 3:

      mix ezagent.snapshot.clear <uri>

  Removes the snapshot row. The next time the Kind is spawned, it will
  init_fresh (granted caps / runtime state lost).
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)

    case args do
      [uri] when is_binary(uri) ->
        case Ezagent.Ecto.KindSnapshot.get(uri) do
          nil ->
            Mix.shell().info("no snapshot at #{uri} (nothing to clear)")

          _row ->
            :ok = Ezagent.Ecto.KindSnapshot.delete(uri)
            Mix.shell().info("✓ cleared snapshot at #{uri}")
        end

      _ ->
        Mix.raise("usage: mix ezagent.snapshot.clear <uri>")
    end
  end
end
