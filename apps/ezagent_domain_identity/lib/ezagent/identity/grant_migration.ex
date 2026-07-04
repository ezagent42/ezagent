defmodule Ezagent.Identity.GrantMigration do
  @moduledoc """
  chat→session rename (Allen 2026-06-12, NO back-compat) — rewrite persisted
  capability grants whose `behavior` is the OLD `Ezagent.ActionSet.Chat` module
  to the NEW `Ezagent.ActionSet.Session`.

  ## Why this exists

  The internal "Chat" Behavior was renamed to `Ezagent.ActionSet.Session`. A
  cap minted under the old code persists `behavior: Ezagent.ActionSet.Chat` in
  TWO places:

    1. `users.caps_json` — the caps SSOT (JSON; behavior stored as the string
       `"Elixir.Ezagent.ActionSet.Chat"`). `Ezagent.ActionSet.Identity.activate/2`
       reconciles its in-memory caps FROM this column on every start.
    2. The `:identity` slice in `kind_snapshots` — the cache (binary term;
       behavior stored as the atom `Ezagent.ActionSet.Chat`).

  After the rename, `Capability.matches?/2` compares `behavior` by equality, so
  a stored `Ezagent.ActionSet.Chat` cap can no longer authorize a
  `Ezagent.ActionSet.Session` dispatch — the grant is silently dead. Worse, the
  caps_json decoder (`Capability.from_map/1` → `String.to_existing_atom/1`)
  rescues an unresolvable old-module string to `:any`, silently BROADENING the
  cap. This migration rewrites the OLD module string/atom to the NEW one BEFORE
  the new code reads it.

  Fresh test users get `Behavior.Session` grants directly from
  `binding_policy` (and the system-principal catalog), so the TEST SUITE passes
  WITHOUT running this migration — it is the PRODUCTION cutover path only.

  ## Deploy ordering

  Run alongside `Ezagent.Session.SliceMigration` in the same ordered cutover
  (stop nodes → deploy → migrate → start). Order between the two does not
  matter: they touch disjoint data (this one: `users.caps_json` + `:identity`
  slice caps; the slice migration: the top-level `:chat`→`:session` slice key).

  ## Migration boundary

  TEST / sandbox DB only here. Do NOT run against a live/dev/prod node — write
  + test it, then run it only as the operator cutover step.
  """

  require Logger

  alias EzagentCore.Repo
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Users

  # String forms as they appear in `caps_json` (Jason-encoded). The behavior is
  # stored via `Ezagent.Capability.Normalize.atom_or_module_to_string/1`, which
  # for a module yields the full `Elixir.`-prefixed name.
  @old_behavior_string "Elixir.Ezagent.ActionSet.Chat"
  @new_behavior_string "Elixir.Ezagent.ActionSet.Session"

  # Atom forms (as stored inside a `:identity` slice's `%Capability{}` in the
  # snapshot binary). Referencing the new module here creates a normal compile
  # dependency; the old atom is referenced as a literal (it may no longer be a
  # loaded module, but `:erlang.binary_to_term` recreates the atom regardless).
  @old_behavior_atom :"Elixir.Ezagent.ActionSet.Chat"
  @new_behavior_atom Ezagent.ActionSet.Session

  @doc """
  Pure transform on a raw `caps_json` STRING: rewrite every occurrence of the
  old `Ezagent.ActionSet.Chat` behavior to `Ezagent.ActionSet.Session`.

  Operates on the encoded JSON text (a global string replace on the exact
  `"Elixir.Ezagent.ActionSet.Chat"` token, which only ever appears as a
  `"behavior"` value — it is a fully-qualified module name, not a substring of
  any other cap field). Returns `{:changed, new_json}` when a rewrite happened,
  `{:unchanged, json}` otherwise.
  """
  @spec rewrite_caps_json(String.t()) :: {:changed, String.t()} | {:unchanged, String.t()}
  def rewrite_caps_json(json) when is_binary(json) do
    if String.contains?(json, @old_behavior_string) do
      {:changed, String.replace(json, @old_behavior_string, @new_behavior_string)}
    else
      {:unchanged, json}
    end
  end

  @doc """
  Pure transform on a decoded `%Capability{}`: rewrite its `behavior` field
  from the old Chat module (string OR atom form) to `Ezagent.ActionSet.Session`.
  Any other behavior is returned unchanged.
  """
  @spec rewrite_cap(map()) :: map()
  def rewrite_cap(%{behavior: behavior} = cap)
      when behavior == @old_behavior_atom or behavior == @old_behavior_string do
    %{cap | behavior: @new_behavior_atom}
  end

  def rewrite_cap(cap), do: cap

  @doc """
  Run the grant rewrite over both persisted homes.

  Options:
    * `:dry_run` (boolean, default `false`) — report without writing.

  Returns `{:ok, %{users_scanned, users_rewritten, snapshots_scanned,
  snapshots_rewritten, dry_run}}`.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    users = migrate_users(dry_run?)
    snaps = migrate_snapshots(dry_run?)

    {:ok, Map.merge(users, snaps)}
  end

  @doc """
  Go/no-go gate. Returns `{:ok, count}` where `count` is the number of
  persisted homes (users rows + `:identity` snapshot rows) that STILL reference
  the old `Ezagent.ActionSet.Chat` behavior. `0` is the green light.
  """
  @spec gate() :: {:ok, non_neg_integer()}
  def gate do
    stale_users =
      user_rows()
      |> Enum.count(fn row -> is_binary(row.caps_json) and String.contains?(row.caps_json, @old_behavior_string) end)

    stale_snaps =
      KindSnapshot.list_all()
      |> Enum.count(&snapshot_has_old_chat_cap?/1)

    {:ok, stale_users + stale_snaps}
  end

  # --- users.caps_json -------------------------------------------------------

  defp migrate_users(dry_run?) do
    user_rows()
    |> Enum.reduce(%{users_scanned: 0, users_rewritten: 0, dry_run: 0}, fn row, acc ->
      acc = %{acc | users_scanned: acc.users_scanned + 1}
      json = row.caps_json || ""

      case rewrite_caps_json(json) do
        {:changed, new_json} ->
          if dry_run? do
            %{acc | dry_run: acc.dry_run + 1}
          else
            row
            |> Ecto.Changeset.change(caps_json: new_json)
            |> Repo.update!()

            %{acc | users_rewritten: acc.users_rewritten + 1}
          end

        {:unchanged, _} ->
          acc
      end
    end)
  end

  defp user_rows do
    Repo.all(Users)
  end

  # --- :identity slice caps in kind_snapshots --------------------------------

  defp migrate_snapshots(dry_run?) do
    KindSnapshot.list_all()
    |> Enum.reduce(%{snapshots_scanned: 0, snapshots_rewritten: 0}, fn row, acc ->
      acc = %{acc | snapshots_scanned: acc.snapshots_scanned + 1}

      case rewrite_snapshot_state(row) do
        {:changed, new_state} ->
          unless dry_run?, do: persist_snapshot(row, new_state)
          %{acc | snapshots_rewritten: acc.snapshots_rewritten + 1}

        :unchanged ->
          acc
      end
    end)
  end

  # Decode → rewrite any `:identity` slice cap whose behavior is the old Chat
  # module → return `{:changed, new_state}` or `:unchanged`. An undecodable row
  # is left alone here (the slice migration / runtime owns that failure mode).
  defp rewrite_snapshot_state(row) do
    case KindSnapshot.decode_state(row) do
      {:ok, state} when is_map(state) ->
        {new_state, changed?} = rewrite_identity_caps(state)
        if changed?, do: {:changed, new_state}, else: :unchanged

      _ ->
        :unchanged
    end
  end

  # The `:identity` slice (two-container `%{state: %{caps: caps}}` OR a legacy
  # flat `%{caps: caps}`) holds the caps. Rewrite each cap; report whether
  # anything changed.
  defp rewrite_identity_caps(state) do
    case Map.fetch(state, :identity) do
      {:ok, %{state: %{caps: caps} = inner} = slice} ->
        {new_caps, changed?} = rewrite_cap_collection(caps)
        {Map.put(state, :identity, %{slice | state: %{inner | caps: new_caps}}), changed?}

      {:ok, %{caps: caps} = slice} ->
        {new_caps, changed?} = rewrite_cap_collection(caps)
        {Map.put(state, :identity, %{slice | caps: new_caps}), changed?}

      _ ->
        {state, false}
    end
  end

  defp rewrite_cap_collection(%MapSet{} = caps) do
    {list, changed?} = rewrite_cap_collection(MapSet.to_list(caps))
    {MapSet.new(list), changed?}
  end

  defp rewrite_cap_collection(caps) when is_list(caps) do
    Enum.map_reduce(caps, false, fn cap, changed? ->
      new_cap = rewrite_cap(cap)
      {new_cap, changed? or new_cap != cap}
    end)
  end

  defp rewrite_cap_collection(other), do: {other, false}

  defp snapshot_has_old_chat_cap?(row) do
    case KindSnapshot.decode_state(row) do
      {:ok, state} when is_map(state) ->
        {_new, changed?} = rewrite_identity_caps(state)
        changed?

      _ ->
        false
    end
  end

  defp persist_snapshot(row, new_state) do
    binary =
      new_state
      |> Ezagent.Kind.Snapshot.strip_transients()
      |> :erlang.term_to_binary()

    case KindSnapshot.upsert(row.uri, row.kind_type, binary, row.version, row.workspace_uri) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        raise "Ezagent.Identity.GrantMigration: failed to persist rewritten " <>
                ":identity caps for #{row.uri}: #{inspect(reason)}"
    end
  end
end
