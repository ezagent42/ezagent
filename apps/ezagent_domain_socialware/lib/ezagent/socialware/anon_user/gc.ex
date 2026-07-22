defmodule Ezagent.Socialware.AnonUser.GC do
  @moduledoc """
  Garbage collection for abandoned anonymous external users (issue #51, spec §3.4).

  An anon-User is reaped 48h after its `last_seen_at`: `chat.leave` from its
  session + delete the `users` row + delete the binding row + best-effort stop the
  Kind. The sweeper is an **in-app supervised `GenServer`** re-arming via
  `Process.send_after/3` (hourly) — NOT Oban, which is absent from the dependency
  tree (this is the post-collapse revision of the draft's Oban-cron proposal).

  ## STATUS

  - `expired?/2` — the PURE TTL predicate — is IMPLEMENTED + tested GREEN.
  - `ttl_ms/0` — the 48h budget — is IMPLEMENTED.
  - `sweep/1` — the table-backed reap pass — is IMPLEMENTED (#51): it walks
    `AnonBinding.list_expired/2`, claims each via the non-destructive compare-and-
    update `claim_for_reaping/3`, then `chat.leave`s + deletes the `users` row +
    best-effort stops the Kind + hard-deletes the binding LAST. Driven by
    `Ezagent.Socialware.AnonUser.Sweeper` (the in-app GenServer) on a fixed interval.
  """

  require Logger

  alias Ezagent.Socialware.AnonBinding

  @ttl_ms 48 * 60 * 60 * 1000

  # Telemetry emitted when the sweep could NOT progress an expired candidate this
  # pass — the claim raised (`:claim_failed`), the leave was unconfirmable
  # (`:leave_unconfirmed`), or the `users` row survived `Users.delete`
  # (`:user_delete_not_confirmed`). The binding stays `reaping_at`-claimed (or
  # unclaimed) for the next sweep. Measurements `%{count: 1}`; metadata
  # `%{entity_uri, session_uri, reason}`. Operators alert on this to detect a
  # retry loop / degraded dependency (codex r4/r5).
  @reap_unconfirmed_event [:ezagent, :socialware, :gc, :reap_unconfirmed]

  @doc "The telemetry event emitted when a sweep candidate could not be reaped this pass."
  @spec reap_unconfirmed_event() :: [atom()]
  def reap_unconfirmed_event, do: @reap_unconfirmed_event

  @doc "The abandonment TTL in milliseconds (48h)."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Whether an anon-User last seen at `last_seen_at` is expired relative to `now`
  (both `DateTime`). Expired iff `now - last_seen_at >= ttl_ms`. Pure.
  """
  @spec expired?(DateTime.t(), DateTime.t()) :: boolean()
  def expired?(%DateTime{} = last_seen_at, %DateTime{} = now) do
    DateTime.diff(now, last_seen_at, :millisecond) >= @ttl_ms
  end

  @doc """
  Reap every anon-User whose binding `last_seen_at` is older than the TTL as of
  `now`. Returns `{:ok, count}` where `count` is the number reaped this pass.

  Per row, **non-destructive claim → destroy → delete index LAST**:

  1. `AnonBinding.claim_for_reaping/3` — compare-and-UPDATE `reaping_at` under the
     SAME `last_seen_at <= cutoff` predicate `list_expired/2` used. `{:ok, :claimed}`
     is the authority to destroy; `{:ok, :not_claimed}` means a concurrent `touch/3`
     refreshed it (or another sweeper holds it) → SKIP, nothing destructive.
  2. On a claim: `chat.leave` the anon-User from its session (`session.leave`
     dispatch under the genesis admin entity with a target-signed
     `session.leave` cap — the anon holds no `:leave` cap and cannot self-leave,
     §3.3; #154 甲-6 eliminated the former `system://socialware-gc` principal),
     delete its `users`
     row (`Users.delete/1`), best-effort stop its Kind, then **hard-delete the
     binding LAST** (`AnonBinding.delete/1`).

  ## Crash-safety

  The binding row is BOTH the GC index and the claim token, so it must survive every
  destructive step — it is hard-deleted only at the very end. A crash (or a dropped
  leave) anywhere mid-reap leaves the row stuck in `reaping_at`, which
  `list_expired/2` re-surfaces past a staleness threshold so the next sweep retries
  it; all reap steps are idempotent, so a double-reap is harmless. A delete-as-claim
  (the row gone before cleanup) would instead leak an orphan no future sweep could
  rediscover (codex review) — this ordering closes that.

  The leave is `:cast` (the Session `:leave` action is cast-only), so it carries no
  delivery acknowledgement. Rather than TRUST the cast, the reap **confirms the
  member was actually removed** — it reads the session's live `:session` slice and
  re-runs the membership predicate (the same `Ezagent.Session.Membership.authorize/2`
  `ChatFeed` uses). The destructive `users`-delete + binding hard-delete run ONLY
  when the member is confirmed gone from a LIVE session. If the member is still
  present (the cast was buffered / dropped) OR the session is unreadable (can't
  confirm — and may rehydrate with the member), the binding stays claimed and the
  next sweep retries — never an undiscoverable orphan via the leave-delivery path.
  One row's reap failing is isolated; it does not abort the sweep.

  Symmetrically, `Users.delete/1` returns `:ok` even when its `Repo.delete` fails,
  so the reap **verifies the `users` row is actually gone** (`get_by_uri == nil`)
  before hard-deleting the binding (codex r3); a surviving row keeps the binding
  claimed for retry. One bounded residual remains by design: `Users.delete` clears
  the Kind SNAPSHOT inside a `try/rescue → :ok`, so a row-gone-but-snapshot-survived
  state can resurrect only an INERT shell (empty caps, no password, confirmed
  non-member) — not a usable principal. Closing it would mean changing the shared
  identity domain, out of this sweeper's lane.

  Every outcome where the sweep cannot progress a candidate this pass — the claim
  raised (`:claim_failed`), the leave was unconfirmable (`:leave_unconfirmed`), or
  the `users` row survived (`:user_delete_not_confirmed`) — emits the
  `#{inspect(@reap_unconfirmed_event)}` telemetry event so a stuck/retrying sweep is
  ALERTABLE rather than a silent no-op (codex r4/r5); the should-never-happen
  reasons additionally log a warning. The reducer over `claim_for_reaping/3` is
  TOTAL — `{:ok, :claimed}` / `{:ok, :not_claimed}` / `{:error, _}` are each handled,
  so no claim result is silently swallowed.
  """
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()}
  def sweep(%DateTime{} = now) do
    ttl = ttl_ms()

    reaped =
      now
      |> AnonBinding.list_expired(ttl)
      |> Enum.reduce(0, fn binding, acc ->
        case AnonBinding.claim_for_reaping(binding.entity_uri, now, ttl) do
          {:ok, :claimed} ->
            if reap(binding), do: acc + 1, else: acc

          # Expected contention: a concurrent `touch/3` refreshed the row past the
          # cutoff, or another sweeper already holds the claim. Normal race
          # resolution — never destroy without a claim, and nothing to surface.
          {:ok, :not_claimed} ->
            acc

          # The claim ITSELF failed — `claim_for_reaping/3` rescues a `Repo.update_all`
          # exception (DB write error / schema drift) into `{:error, _}`. Distinct from
          # `:not_claimed`: the candidate is skipped through NO contention, so it MUST
          # be observable (codex r5) rather than silently folded into a clean
          # `{:ok, 0}` pass under exactly the degraded conditions this sweeper exists to
          # surface. Telemetry + warn, then continue — one row's claim failing does not
          # abort the sweep (same isolation as `reap/1`'s rescue). Handling this arm
          # makes the reducer TOTAL: every `claim_for_reaping/3` return is now accounted
          # for and observable.
          {:error, _reason} ->
            signal_stuck_reap(binding.entity_uri, binding.session_uri, :claim_failed)
            acc
        end
      end)

    {:ok, reaped}
  end

  # Reap a SINGLE claimed binding: cast the leave, then CONFIRM the member was
  # actually removed from the live session before any destructive op. Only on a
  # confirmed removal: delete the `users` row + best-effort stop the Kind + hard-
  # delete the binding LAST (so a crash before that re-surfaces the still-`reaping_at`
  # row for retry). If the member is still present (cast buffered/dropped) or the
  # session is unreadable, the binding stays claimed and the next sweep retries.
  # Isolated so one bad row does not abort the sweep; returns whether it was reaped.
  defp reap(%AnonBinding{entity_uri: entity_uri, session_uri: session_uri}) do
    leave_session(session_uri, entity_uri)

    if member_removed?(session_uri, entity_uri) do
      _ = Ezagent.Users.delete(entity_uri)
      _ = best_effort_terminate(entity_uri)

      if user_gone?(entity_uri) do
        {:ok, _} = AnonBinding.delete(entity_uri)
        true
      else
        # `Users.delete/1` returns `:ok` UNCONDITIONALLY — it discards a failed
        # `Repo.delete` (users.ex). So rather than ASSUME the provisioning row is
        # gone, VERIFY it (codex r3) before hard-deleting the binding. If the row
        # survived, keep the binding `reaping_at`-claimed so the next sweep retries
        # — never delete the GC index while the `users` row it points at still
        # exists (that would orphan a row no future sweep could rediscover). A
        # defensive postcondition: `Repo.delete` on a freshly-fetched row has no
        # FK-restrict here, so this false-branch is rarely reached in practice.
        #
        # But a stuck reap MUST be observable, not a silent no-op (codex r4): the
        # binding is held claimed indefinitely while a live `users` row lingers, so
        # emit telemetry + warn so operators can alert on a repeatedly-stale
        # `reaping_at` instead of mistaking it for "no eligible work" (§3.4 / the
        # no-silent-failure principle).
        signal_stuck_reap(entity_uri, session_uri, :user_delete_not_confirmed)
        false
      end
    else
      # Leave could NOT be confirmed — the member is still present (cast buffered) or
      # the session is unreadable/down (and may rehydrate WITH the member). This is
      # EXPECTED backpressure, not an error, so emit telemetry (visibility) but NO
      # warning-level log: the binding stays claimed and the next sweep retries.
      signal_stuck_reap(entity_uri, session_uri, :leave_unconfirmed)
      false
    end
  rescue
    e ->
      Logger.warning(
        "Socialware GC: reap of #{inspect(entity_uri)} failed mid-pass: " <>
          "#{inspect(e)} — row stays claimed (reaping_at); retried next sweep (§3.4)."
      )

      false
  end

  # Confirm the anon-User is no longer a member of its session — the delivery-
  # agnostic ack the `:cast` leave cannot provide. Reads the live `:session` slice
  # (a `GenServer.call`, so mailbox-ordered after the queued leave) and re-runs the
  # SAME membership predicate `ChatFeed` uses. `:ok` (still a member) or an
  # unreadable slice (session down/gone — may rehydrate WITH the member) → NOT
  # confirmed → keep the binding claimed for retry.
  defp member_removed?(session_uri, entity_uri)
       when is_binary(session_uri) and is_binary(entity_uri) do
    case Ezagent.Kind.get_slice(Ezagent.URI.new!(session_uri), :session) do
      {:ok, slice} ->
        match?(
          {:error, _},
          Ezagent.Session.Membership.authorize(
            slice,
            Ezagent.URI.new!(entity_uri),
            Ezagent.URI.new!(session_uri),
            Ezagent.URI.new!(entity_uri)
          )
        )

      _ ->
        false
    end
  end

  # Confirm the provisioning `users` row is actually gone after `Users.delete/1`
  # (which returns `:ok` even on a failed `Repo.delete`). The verify-after that
  # turns "assume reaped" into "prove reaped" before the binding is hard-deleted.
  # NOTE: this checks the `users` ROW, not the Kind snapshot — `Users.delete`
  # clears the snapshot via `Lifecycle.destroy` inside a `try/rescue → :ok`, so a
  # row-gone-but-snapshot-survived state is possible. That residual resurrects only
  # an INERT shell (empty caps, no password_hash, confirmed non-member) — not a
  # usable principal — and removing it would mean changing the shared identity
  # domain (`Users.delete` / `Lifecycle.destroy`), out of this sweeper's lane. So
  # the binding delete is gated on the row alone; the snapshot residual is a bounded,
  # inert leftover by design.
  defp user_gone?(entity_uri) when is_binary(entity_uri) do
    Ezagent.Users.get_by_uri(entity_uri) == nil
  end

  # Make a skipped/incomplete reap OBSERVABLE rather than a silent no-op (codex
  # r4/r5): always emit telemetry so a candidate the sweep could NOT progress is
  # alertable, not indistinguishable from "nothing to reap". Log severity splits by
  # reason — EXPECTED backpressure is telemetry-only (a warning each sweep would be
  # noise); SHOULD-NEVER-HAPPEN reasons also warn:
  #
  #   * `:leave_unconfirmed` — cast buffered / session down → telemetry only.
  #   * `:user_delete_not_confirmed` — member confirmed gone yet `Users.delete`
  #     reported `:ok` while the row survived → telemetry + WARN.
  #   * `:claim_failed` — `claim_for_reaping/3` raised (DB write / schema drift) →
  #     telemetry + WARN.
  defp signal_stuck_reap(entity_uri, session_uri, reason)
       when is_binary(entity_uri) and is_binary(session_uri) and is_atom(reason) do
    :telemetry.execute(
      @reap_unconfirmed_event,
      %{count: 1},
      %{entity_uri: entity_uri, session_uri: session_uri, reason: reason}
    )

    case warn_message(reason, entity_uri) do
      nil -> :ok
      msg -> Logger.warning(msg)
    end

    :ok
  end

  # `nil` → telemetry only (expected backpressure); a string → also warn (anomalous).
  defp warn_message(:leave_unconfirmed, _entity_uri), do: nil

  defp warn_message(:user_delete_not_confirmed, entity_uri) do
    "Socialware GC: reap of #{inspect(entity_uri)} left the users row live " <>
      "(Users.delete reported :ok but get_by_uri still resolves) — binding stays " <>
      "claimed (reaping_at), retried next sweep (§3.4)."
  end

  defp warn_message(:claim_failed, entity_uri) do
    "Socialware GC: claim of #{inspect(entity_uri)} FAILED " <>
      "(claim_for_reaping raised — DB write / schema drift?) — candidate skipped this " <>
      "pass, retried next sweep (§3.4)."
  end

  # `chat.leave` the anon-User from its session via the sanctioned `session.leave`
  # dispatch. `:cast` — eventually-consistent; a failure DLQs.
  #
  # System-principal elimination (#154 甲-6): the ambient `system://socialware-gc`
  # principal is DELETED. Reaping an abandoned anon is SYSTEM MAINTENANCE — the
  # anon itself holds no `:leave` cap (甲-2 mounts unconfirmed members only
  # `subscribe_from`), so the authority is the genesis admin entity
  # `entity://system/user/admin` (which has authority over every session), exactly
  # as the operator CLI now routes (mix-task #833). The reaper obtains the narrow
  # receiver-bound `session.leave` artifact through the target's `K.grant` path.
  defp leave_session(session_uri, member_uri)
       when is_binary(session_uri) and is_binary(member_uri) do
    target = Ezagent.URI.new!(session_uri <> "?action=session.leave")
    admin_uri = Ezagent.Entity.User.admin_uri()

    with {:ok, _pid} <- Ezagent.KindRegistry.lookup(Ezagent.URI.instance(target)),
         {:ok, leave_cap} <-
           Ezagent.Cap.issue_for_action({:admin, admin_uri}, admin_uri, target) do
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{member: Ezagent.URI.new!(member_uri)},
        ctx: %{
          caller: admin_uri,
          authenticated_principal: admin_uri,
          caps: MapSet.new([leave_cap]),
          reply: :ignore
        },
        origin: :trusted_internal
      })

      :ok
    end
  end

  # Best-effort terminate the anon-User Kind if alive (anon-Users demand-spawn, so
  # frequently no live Kind exists — a `:ok` no-op).
  defp best_effort_terminate(entity_uri) when is_binary(entity_uri) do
    uri = Ezagent.URI.new!(entity_uri)

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} -> Ezagent.Kind.terminate!(uri)
      :error -> :ok
    end
  rescue
    _ -> :ok
  end
end
