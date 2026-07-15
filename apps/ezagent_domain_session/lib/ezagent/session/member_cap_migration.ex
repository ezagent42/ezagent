defmodule Ezagent.Session.MemberCapMigration do
  @moduledoc """
  Membership-cap unification A1.4 (spec R1.5 / R2.2 / R3.2) — backfill the
  universal member-cap `cap(:session, Session, :receive, S)` onto every existing
  session member, for sessions that pre-date the at-join grant (A1.2).

  ## READ via repo (paginated), WRITE via the LIVE grant path (R2.2)

  The enumeration is a **repo-only, keyset-paginated READ** over `kind_snapshots`
  `where kind_type == "session"` — a WHERE clause (NOT `list_all`), `order_by uri`,
  `uri > last_uri`, bounded `@page`. Each row is decoded ONCE; `members` AND
  `owner_uri` are read from the SAME decoded persisted state (never a live/racing
  owner lookup). The WRITE goes through `Ezagent.Identity.Grant.grant_cap_via_router/4`
  (the live grant path) so the member's in-memory `:identity` slice AND its
  snapshot stay consistent — so **nodes may be running** (unlike a raw
  `kind_snapshots` write, which a later `:on_change` snapshot would clobber).

  ## Idempotency + confirmation (R3.2)

  Idempotency is keyed on the **exact member-cap identity** (the `identity_key/1`
  5-tuple), NOT on general `matches?/2` authorization — so a session whose owner
  already holds a broad `:any` cap STILL gets its concrete member-cap written. A
  re-run is a no-op (`skipped_already_held`). Grants are **synchronous and
  CONFIRMED**: only a committed `:ok` increments `members_granted`; a `{:error}`
  grant (e.g. an unreachable member Kind) is logged and NOT counted.

  Ownerless sessions fall back to the #154 admin granter (matching
  `public_view_granter/1`), LOGGED and reported as `ownerless_fallback`.

  ## Operator front door

  `mix ezagent.migrate.member_caps [--dry-run] [--gate]` — see the task.
  """

  require Logger
  import Ecto.Query

  alias EzagentCore.Repo
  alias Ezagent.Ecto.KindSnapshot

  @page 100

  @type report :: %{
          sessions_scanned: non_neg_integer(),
          members_granted: non_neg_integer(),
          skipped_already_held: non_neg_integer(),
          ownerless_fallback: non_neg_integer(),
          dry_run: boolean()
        }

  @doc """
  CLI/programmatic entry. `argv` accepts `--dry-run` and `--gate`.

    * `--gate` → `:ok` if every session member holds the exact member-cap, else
      `{:error, {:uncovered_member_caps, count}}` (nonzero-exit signal).
    * otherwise → runs the migration (`--dry-run` reports without writing) and
      returns the `report/0` map.
  """
  @spec run([String.t()]) :: report() | :ok | {:error, term()}
  def run(argv \\ []) when is_list(argv) do
    {opts, _positional, _} =
      OptionParser.parse(argv, switches: [dry_run: :boolean, gate: :boolean])

    cond do
      opts[:gate] -> gate()
      true -> migrate(!!opts[:dry_run])
    end
  end

  @doc "Run the backfill. `dry_run?` reports counts without granting."
  @spec migrate(boolean()) :: report()
  def migrate(dry_run? \\ false) do
    session_rows()
    |> Enum.reduce(
      %{
        sessions_scanned: 0,
        members_granted: 0,
        skipped_already_held: 0,
        ownerless_fallback: 0,
        dry_run: dry_run?
      },
      fn row, acc ->
        acc = %{acc | sessions_scanned: acc.sessions_scanned + 1}

        case decode_session(row) do
          {:ok, session_uri, members, owner} ->
            Enum.reduce(members, acc, fn member_uri, acc ->
              migrate_member(session_uri, member_uri, owner, dry_run?, acc)
            end)

          :skip ->
            acc
        end
      end
    )
  end

  @doc """
  Go/no-go gate. `:ok` iff EVERY session member holds the exact member-cap;
  `{:error, {:uncovered_member_caps, count}}` otherwise.
  """
  @spec gate() :: :ok | {:error, {:uncovered_member_caps, non_neg_integer()}}
  def gate do
    uncovered =
      session_rows()
      |> Enum.reduce(0, fn row, count ->
        case decode_session(row) do
          {:ok, session_uri, members, _owner} ->
            count + Enum.count(members, fn m -> not holds_member_cap_exact?(m, session_uri) end)

          :skip ->
            count
        end
      end)

    if uncovered == 0, do: :ok, else: {:error, {:uncovered_member_caps, uncovered}}
  end

  # --- per-member grant ------------------------------------------------------

  defp migrate_member(session_uri, member_uri, owner, dry_run?, acc) do
    cond do
      holds_member_cap_exact?(member_uri, session_uri) ->
        %{acc | skipped_already_held: acc.skipped_already_held + 1}

      dry_run? ->
        # Report intent without writing — NOT counted as granted (R3.2: only a
        # committed `:ok` counts).
        acc

      true ->
        do_grant(session_uri, member_uri, owner, acc)
    end
  end

  defp do_grant(session_uri, member_uri, owner, acc) do
    ws = Ezagent.Capability.workspace_of(session_uri)
    cap = member_cap(session_uri, ws)
    {granter, ownerless?} = granter_for(owner)

    case Ezagent.Identity.Grant.grant_cap_via_router(
           member_uri,
           cap,
           {:rule, :session_participation, granter},
           :sync
         ) do
      :ok ->
        acc = %{acc | members_granted: acc.members_granted + 1}

        if ownerless? do
          Logger.info(
            "MemberCapMigration: ownerless-fallback admin granter for " <>
              "member=#{URI.to_string(member_uri)} on session=#{URI.to_string(session_uri)}"
          )

          %{acc | ownerless_fallback: acc.ownerless_fallback + 1}
        else
          acc
        end

      {:error, reason} ->
        # Grant-confirmation (R3.2): a failed commit is NOT counted.
        Logger.warning(
          "MemberCapMigration: member-cap grant FAILED (not counted) for " <>
            "member=#{URI.to_string(member_uri)} on session=#{URI.to_string(session_uri)}: " <>
            "#{inspect(reason)}"
        )

        acc
    end
  end

  # Exact-identity idempotency (R3.2): the member already holds THIS concrete
  # member-cap (5-tuple `identity_key/1` equality) — a broad `:any` cap does NOT
  # satisfy it, so the concrete cap is still written.
  defp holds_member_cap_exact?(member_uri, session_uri) do
    ws = Ezagent.Capability.workspace_of(session_uri)
    target_key = Ezagent.Capability.identity_key(member_cap(session_uri, ws))

    member_uri
    |> Ezagent.EntityCaps.load()
    |> Enum.any?(fn
      %Ezagent.Capability{} = cap -> Ezagent.Capability.identity_key(cap) == target_key
      _ -> false
    end)
  end

  defp granter_for(%URI{scheme: "entity"} = owner), do: {owner, false}
  defp granter_for(_), do: {Ezagent.Entity.User.admin_uri(), true}

  defp member_cap(session_uri, ws) do
    Ezagent.Capability.cap(:session, Ezagent.ActionSet.Session, :receive, session_uri, ws)
  end

  # --- keyset-paginated repo read (R2.2 step 1-3) ----------------------------

  # A keyset-paginated enumerable over `kind_snapshots where kind_type ==
  # "session"` — a WHERE clause + `uri`-ordered pages (NOT `list_all`), bounded
  # memory. Nodes may be running; this is a pure READ.
  defp session_rows do
    Stream.resource(
      fn -> "" end,
      fn last_uri ->
        page =
          from(s in KindSnapshot,
            where: s.kind_type == "session" and s.uri > ^last_uri,
            order_by: [asc: s.uri],
            limit: @page
          )
          |> Repo.all()

        case page do
          [] -> {:halt, last_uri}
          rows -> {rows, List.last(rows).uri}
        end
      end,
      fn _ -> :ok end
    )
  end

  # Decode ONCE; read BOTH members AND owner from the SAME persisted state.
  defp decode_session(row) do
    with {:ok, state} when is_map(state) <- KindSnapshot.decode_state(row),
         {:ok, %URI{} = session_uri} <- Ezagent.URI.parse(row.uri) do
      slice = session_slice(state)
      members = slice |> Map.get(:members, %{}) |> member_uris()
      owner = slice |> Map.get(:owner_uri) |> normalize_owner()
      {:ok, session_uri, members, owner}
    else
      _ -> :skip
    end
  end

  defp session_slice(state) do
    (Map.get(state, :session) || Map.get(state, "session") || %{})
    |> Ezagent.Kind.normalize_slice_view()
  end

  defp member_uris(members) when is_map(members) do
    members
    |> Map.keys()
    |> Enum.map(&normalize_owner/1)
    |> Enum.reject(&is_nil/1)
  end

  defp member_uris(_), do: []

  defp normalize_owner(%URI{} = uri), do: uri

  defp normalize_owner(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, %URI{} = u} -> u
      _ -> nil
    end
  end

  defp normalize_owner(_), do: nil
end
