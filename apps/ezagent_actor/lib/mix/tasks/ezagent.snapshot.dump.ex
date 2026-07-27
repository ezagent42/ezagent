defmodule Mix.Tasks.Ezagent.Snapshot.Dump do
  @shortdoc "Decode + print a Kind snapshot for inspection"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (read-only inspect).**
  > Intentionally NOT a dispatched op. Read-only inspection of stored
  > snapshot rows (debug tool). Stays as `mix ezagent.*`; do NOT
  > migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Snapshots row).

  Phase 5 PR 3:

      mix ezagent.snapshot.dump <uri>

  Example:

      mix ezagent.snapshot.dump entity://user/system/admin
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)

    case args do
      [uri] when is_binary(uri) ->
        case Ezagent.Ecto.KindSnapshot.get(uri) do
          nil ->
            Mix.raise("no snapshot at #{uri}")

          row ->
            Mix.shell().info("URI: #{row.uri}")
            Mix.shell().info("Kind: #{row.kind_type}")
            Mix.shell().info("Version: #{row.version}")
            Mix.shell().info("Updated: #{DateTime.to_iso8601(row.updated_at)}")

            Mix.shell().info(
              "Bytes: #{if is_binary(row.state_binary), do: byte_size(row.state_binary), else: 0}"
            )

            Mix.shell().info("\n--- state ---")

            case Ezagent.Ecto.KindSnapshot.decode_state(row) do
              {:ok, state} ->
                Mix.shell().info(inspect(state, pretty: true, limit: :infinity, width: 80))

              {:error, reason} ->
                Mix.raise("decode error: #{inspect(reason)}")
            end
        end

      _ ->
        Mix.raise("usage: mix ezagent.snapshot.dump <uri>")
    end
  end
end
