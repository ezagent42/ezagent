defmodule Mix.Tasks.Ezagent.Snapshot.List do
  @shortdoc "List all per-Kind snapshots in kind_snapshots table"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (read-only inspect).**
  > Intentionally NOT a dispatched op. Read-only listing of stored
  > snapshot rows (debug tool). Stays as `mix ezagent.*`; do NOT
  > migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Snapshots row).

  Phase 5 PR 3: operator visibility into `kind_snapshots`.

      mix ezagent.snapshot.list
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)

    rows = Ezagent.Ecto.KindSnapshot.list_all()

    if rows == [] do
      Mix.shell().info("(no snapshots)")
    else
      Mix.shell().info(
        String.pad_trailing("URI", 50) <>
          String.pad_trailing("KIND", 15) <>
          String.pad_trailing("BYTES", 10) <>
          String.pad_trailing("VER", 5) <>
          "UPDATED"
      )

      Mix.shell().info(String.duplicate("-", 110))

      Enum.each(rows, fn row ->
        bytes = if is_binary(row.state_binary), do: byte_size(row.state_binary), else: 0

        Mix.shell().info(
          String.pad_trailing(row.uri, 50) <>
            String.pad_trailing(row.kind_type || "—", 15) <>
            String.pad_trailing(to_string(bytes), 10) <>
            String.pad_trailing(to_string(row.version), 5) <>
            DateTime.to_iso8601(row.updated_at)
        )
      end)

      Mix.shell().info("\n#{length(rows)} snapshot(s)")
    end
  end
end
