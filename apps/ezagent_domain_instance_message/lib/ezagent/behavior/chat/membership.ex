defmodule Ezagent.Behavior.Chat.Membership do
  @moduledoc false
  #
  # Join machinery extracted VERBATIM from `Ezagent.Behavior.Chat`
  # (PR-3R helper extraction). These functions run in the same Session
  # Kind GenServer process whether defined here or in `Behavior.Chat` —
  # the effect lists they BUILD (`{:set, ...}` / `{:set_transient, ...}` /
  # the membership-broadcast `{:notify, ...}` effects) are emitted by the
  # `handle_join/2` callback in `Behavior.Chat`, and the same-process
  # side-effects (`Process.monitor` / `Process.demonitor` / the owner-cap
  # grant dispatch / `Ezagent.Notifications.notify`) are identical to
  # running in `Behavior.Chat`.

  require Logger

  alias Ezagent.Cmd
  alias Ezagent.Behavior.Chat.{Delivery, Members}

  @doc """
  Add a member to the session — the `:join` handler body. Builds the
  `{:ok, result, [effect]}` tuple the `handle_join/2` callback returns.

  `source_module` is the `Behavior.Chat` module reference used as the
  `:source` on join notifications (preserves the pre-extraction
  `__MODULE__` semantics).
  """
  @spec do_join(URI.t(), pid(), map(), map(), module()) ::
          {:ok, map(), [term()]} | {:error, term()}
  def do_join(%URI{} = member_uri, member_pid, ctx, facets, source_module) do
    members = ctx[:read].(:members, %{})

    # team-routing-unification §3.1 (spec §8 decision #2) — `role_name` is
    # UNIQUE PER SESSION. Reject a join that would assign a role_name already
    # held by a DIFFERENT member BEFORE any monitor side effect, so a rejected
    # join leaks no monitor. A member rejoining with its OWN role_name is fine.
    case Members.role_name_conflict(members, member_uri, Map.get(facets, :role_name)) do
      {:error, _} = err -> err
      :ok -> do_join_apply(member_uri, member_pid, ctx, facets, source_module)
    end
  end

  defp do_join_apply(%URI{} = member_uri, member_pid, ctx, facets, source_module) do
    session_uri = ctx[:self_uri]
    members = ctx[:read].(:members, %{})
    # `:monitors` is a TRANSIENT (SPEC §2.3C) — read from ctx.transients.
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})
    prior_owner = ctx[:read].(:owner_uri, nil)

    # Drop ALL stale monitor entries for this member URI and DEMONITOR
    # each ref (Codex r1 MEDIUM-3, 2026-05-26).
    {old_refs_for_member, monitors_without_member} =
      Enum.split_with(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    for {ref, _uri} <- old_refs_for_member do
      _ = Process.demonitor(ref, [:flush])
    end

    monitors_without_member = Map.new(monitors_without_member)

    ref = Process.monitor(member_pid)

    # team-routing-unification §3.1 (codex PR-5a HIGH #2) — PRESERVE any
    # facets a faceted member already carries when it rejoins through the
    # stale-monitor / offline path. Start from the EXISTING meta (not a fresh
    # `%{online: true}`), force `online: true`, then overlay only the non-nil
    # facets this join supplied. Durable management/snapshot facets therefore
    # survive reconnect/repair instead of being silently dropped.
    existing_meta = Map.get(members, member_uri, %{})

    new_members =
      Map.put(
        members,
        member_uri,
        Members.put_member_facets(Map.put(existing_meta, :online, true), facets)
      )

    new_monitors = Map.put(monitors_without_member, ref, member_uri)

    # If this member has prior last_seen, replay missed messages.
    Delivery.replay_messages_since(session_uri, member_uri, last_seen)
    new_last_seen = Map.delete(last_seen, member_uri)

    # RFC #402 (Allen 2026-05-26) — "first user to join is owner"
    # fallback.
    new_owner_uri =
      if is_nil(prior_owner) and user_uri?(member_uri) do
        member_uri
      else
        prior_owner
      end

    # RFC #402 (codex r1 HIGH 2026-05-26) — when this join transitions
    # `owner_uri` from `nil` to a real user, ALSO grant that user the
    # `OrchestratorAdmin :restart` cap on this session.
    if is_nil(prior_owner) and user_uri?(member_uri) do
      grant_first_join_owner_cap(session_uri, member_uri)
    end

    # Notifier/flash audit 2026-05-24 — todo.md "Notifications consumer
    # coverage" — surface the join to the joinee's notification stream
    # so a freshly-added member sees they were added to a session.
    if user_uri?(member_uri) do
      _ =
        Ezagent.Notifications.notify(member_uri, %{
          type: :session_member_joined,
          body: %{
            text: "You joined session #{URI.to_string(session_uri)}.",
            session_uri: session_uri
          },
          source: source_module
        })
    end

    {:ok, %{members: Map.keys(new_members)},
     [
       {:set, :members, new_members},
       # `:monitors` is a TRANSIENT (SPEC §2.3C / §7 OQ-2) — written via
       # `:set_transient`, never persisted.
       {:set_transient, :monitors, new_monitors},
       {:set, :last_seen, new_last_seen},
       {:set, :owner_uri, new_owner_uri}
     ] ++ Delivery.broadcast_membership_effects(session_uri, {:member_joined, member_uri})}
  end

  # Notifier/flash audit 2026-05-24 — same predicate
  # `Ezagent.Domain.Workspace.user_uri?/1` uses. Keeps the agent-target
  # silence guarantee local to Chat without crossing the
  # workspace-domain boundary.
  @doc """
  True iff `uri` is an `entity://user/...` URI. Mirrors
  `Ezagent.Domain.Workspace.user_uri?/1` to keep the agent-target silence
  guarantee local to Chat.
  """
  @spec user_uri?(term()) :: boolean()
  def user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  def user_uri?(_), do: false

  # RFC #402 (codex r1 HIGH 2026-05-26) — companion to the
  # first-USER-join owner claim. Dispatches `identity.grant_cap` on
  # the new owner so they hold the specific
  # `cap(:session, OrchestratorAdmin, :restart, session_uri, ws)`
  # cap the LV's restart gate consults.
  #
  # `mode: :cast` is REQUIRED here (NOT :call). We're currently
  # executing inside the Session Kind's `GenServer.call` (the
  # `chat.join` invocation), and `identity.grant_cap` dispatches
  # to the IdentityAdmin Behavior which runs
  # `check_grant_authorized` → `data_owner_of(OrchestratorAdmin,
  # session_uri)` → `OrchestratorAdmin.data_owner` →
  # `Chat.data_owner` → `Session.owner(session_uri)` →
  # `Ezagent.Kind.get_slice(session_uri, :chat)` which is itself
  # a `GenServer.call` to this very Session. A `:call`-mode
  # grant_cap dispatch therefore deadlocks (5-sec timeout, then
  # `:join` crashes with `:exit`).
  #
  # `:cast` enqueues the grant_cap dispatch to the User Kind's
  # mailbox and returns immediately; by the time IdentityAdmin
  # gets around to calling `Session.owner`, this Session has
  # already returned from `chat.join` and is ready for the next
  # message. Eventually-consistent: a tight LV remount + restart
  # within the cast latency window MIGHT see the cap not yet
  # granted; the gap is bounded by the User Kind mailbox queue
  # depth + one `get_slice` round-trip (sub-ms in practice).
  # Acceptable per RFC #402 — the legacy fallback path is rare.
  defp grant_first_join_owner_cap(%URI{} = session_uri, %URI{} = owner_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = workspace_uri} ->
        want = %Ezagent.Capability{
          kind: :session,
          behavior: Ezagent.Behavior.OrchestratorAdmin,
          # SPEC 2026-05-27 capability-action-axis — OrchestratorAdmin
          # actions/0 == [:restart].
          action: :restart,
          instance: session_uri,
          workspace_uri: workspace_uri,
          granted_by: owner_uri,
          granted_at: DateTime.utc_now()
        }

        case Ezagent.Router.dispatch(%Cmd{
               target: owner_uri,
               action: :grant_cap,
               args: %{cap: want},
               ctx: %{
                 caller: owner_uri,
                 caps: system_caps("template-materialize"),
                 reply: :ignore
               }
             }) do
          :ok ->
            :ok

          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Chat.grant_first_join_owner_cap: cast dispatch failed for " <>
                "owner=#{URI.to_string(owner_uri)} on session=" <>
                "#{URI.to_string(session_uri)}: #{inspect(reason)}. " <>
                "Restart UX will be re-attempted on the next navigation."
            )

            :telemetry.execute(
              [:ezagent, :chat, :first_join_owner_cap, :failed],
              %{count: 1},
              %{session_uri: session_uri, owner_uri: owner_uri, reason: reason}
            )

            :ok
        end

      :error ->
        # Session not workspace-bound.
        :ok
    end
  end

  defp system_caps(name) when is_binary(name) do
    name
    |> Ezagent.SystemPrincipal.uri()
    |> Ezagent.SystemPrincipal.caps()
  end
end
