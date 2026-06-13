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
  - `sweep/1` — the table-backed reap pass — is PENDING the anon binding table
    (the `anon_user_gc_test.exs` end-to-end reap case is `@tag :pending_impl` /
    `:skip`). It currently returns `{:error, :not_implemented}` so a caller fails
    loudly rather than silently no-op'ing (no shim masking a missing table).
  """

  @ttl_ms 48 * 60 * 60 * 1000

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
  Reap every anon-User whose `last_seen_at` is older than the TTL as of `now`.

  PENDING the anon binding table — see the moduledoc. Returns
  `{:error, :not_implemented}` until the table + leave/delete pass land.
  """
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, :not_implemented}
  def sweep(%DateTime{} = _now), do: {:error, :not_implemented}
end
