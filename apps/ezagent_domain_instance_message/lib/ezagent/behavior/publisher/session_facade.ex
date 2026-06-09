defmodule Ezagent.Behavior.Publisher.SessionFacade do
  @moduledoc """
  Shared Kind-side façade for the `Ezagent.Behavior.Publisher` contract.

  Every session Kind that composes `Ezagent.Behavior.Publisher.SessionImpl`
  (today `Ezagent.Entity.Session` and, since the P0 socialware substrate,
  `Ezagent.Entity.SocialwareSession`) needs the SAME caller-facing publisher
  API: the 2-ary / 4-ary public variants that route each publisher action
  through `Ezagent.Invocation.dispatch/1` (so caps gate at CapBAC step 5.5 and
  workspace isolation at step 5.6), plus the no-ambient-caps raisers behind the
  3-ary `@behaviour` contract.

  This module is the SINGLE implementation of that façade so the per-Kind
  modules only `defdelegate` / wrap it — there is no copy-paste fork across
  session Kinds (arch fitness `cross_file_duplicate_fn_groups`). The actual
  ring + cursor + subscriber bookkeeping still lives in
  `Ezagent.Behavior.Publisher.SessionImpl` (the Behavior added to each Kind's
  `behaviors/0`); this façade is purely the dispatch wrapper.

  The functions are Kind-agnostic: they take the publisher `%URI{}` plus the
  caller-supplied `ctx` and dispatch generically, so a single implementation
  serves every session Kind.
  """

  @doc """
  4-ary `subscribe_from` that dispatches with the caller-supplied ctx.

  `ctx` MUST carry `:caller` (a `%URI{}`) and `:caps`
  (a `MapSet.t(%Ezagent.Capability{})`); CapBAC step 5.5 denies with
  `{:error, :unauthorized}` otherwise (no ambient-caps fallback).
  Returns `{:ok, current_cursor}` on success.
  """
  @spec subscribe_from(URI.t(), pid(), Ezagent.Behavior.Publisher.cursor(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def subscribe_from(%URI{} = publisher_uri, subscriber_pid, cursor, ctx)
      when is_pid(subscriber_pid) and is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(
      :subscribe_from,
      %{subscriber_pid: subscriber_pid, cursor: cursor},
      ctx
    )
    |> unwrap_cursor()
  end

  @doc "2-ary `snapshot` with explicit caller ctx — see `subscribe_from/4`."
  @spec snapshot(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def snapshot(%URI{} = publisher_uri, ctx) when is_map(ctx),
    do: dispatch_publisher_action(publisher_uri, :snapshot, %{}, ctx)

  @doc "4-ary `history` with explicit caller ctx — see `subscribe_from/4`."
  @spec history(
          URI.t(),
          Ezagent.Behavior.Publisher.cursor(),
          Ezagent.Behavior.Publisher.cursor(),
          map()
        ) ::
          {:ok, [Ezagent.Publisher.Event.t()]} | {:error, term()}
  def history(%URI{} = publisher_uri, from, to, ctx) when is_map(ctx) do
    publisher_uri
    |> dispatch_publisher_action(:history, %{from: from, to: to}, ctx)
    |> unwrap_events()
  end

  @doc """
  Raise the no-ambient-caps error for a session Kind's 3-ary `@behaviour`
  callback. `kind_module` is the calling Kind (used only for the message).
  """
  @spec raise_no_ambient_caps!(module(), atom(), pos_integer()) :: no_return()
  def raise_no_ambient_caps!(kind_module, action, arity) do
    raise ArgumentError,
          "#{inspect(kind_module)}.#{action}/#{arity - 1} (the @behaviour " <>
            "Ezagent.Behavior.Publisher 3-ary contract callback) requires an " <>
            "explicit caller ctx — use #{inspect(kind_module)}.#{action}/#{arity} " <>
            "with `ctx: %{caller: %URI{...}, caps: MapSet.new([...])}` instead. " <>
            "The V1 codebase has no ambient-caps mechanism; every dispatch " <>
            "must declare its caller + caps so CapBAC step 5.5 can gate " <>
            "non-Worker access (codex round-1 CRITICAL, 2026-05-25)."
  end

  # Build + dispatch a publisher action against the publisher URI using the
  # caller-supplied `ctx`. The ctx MUST carry `:caller` + `:caps`; if it
  # doesn't, CapBAC step 5.5 denies with `{:error, :unauthorized}` (let-it-crash
  # posture — no default caps, no implicit admin elevation).
  defp dispatch_publisher_action(%URI{} = publisher_uri, action, args, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(publisher_uri)}?action=publisher.#{action}")

    # Normalise the reply field: callers that didn't supply it get `:ignore`
    # (the result is still returned via the synchronous dispatch tuple — the
    # reply field is only consumed by :cast mode + outbound transports).
    normalised_ctx = Map.put_new(ctx, :reply, :ignore)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: normalised_ctx
    })
  end

  defp unwrap_cursor({:ok, %{cursor: cursor}}), do: {:ok, cursor}
  defp unwrap_cursor({:error, _} = err), do: err

  defp unwrap_events({:ok, %{events: events}}), do: {:ok, events}
  defp unwrap_events({:error, _} = err), do: err
end
