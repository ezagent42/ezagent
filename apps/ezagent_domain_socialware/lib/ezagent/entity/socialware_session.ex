defmodule Ezagent.Entity.SocialwareSession do
  @moduledoc """
  Socialware session Kind.

  P1 composes Chat with the Turn state machine. Surface and publisher
  behavior are added in later phases as their contracts land.
  """

  @behaviour Ezagent.Kind
  @behaviour Ezagent.Behavior.Publisher

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  def behaviors do
    [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Turn,
      Ezagent.Behavior.Surface,
      Ezagent.Behavior.ConfigUpdate,
      # P0 (socialware substrate) — every session composes the Publisher
      # trunk. SessionImpl owns the `:publisher` slice + the 3 publisher
      # actions. No consumer change: the slice simply exists now.
      Ezagent.Behavior.Publisher.SessionImpl
    ]
  end

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainSocialware.SocialwareSessionSupervisor

  # ─────────────────────────────────────────────────────────────────────
  # Ezagent.Behavior.Publisher implementation (P0 socialware substrate)
  #
  # Mirrors `Ezagent.Entity.Session` (ExternalMirror PR-EM-0): the four
  # `@behaviour` callbacks satisfy the Publisher contract; the public
  # 2-ary/4-ary variants route every publisher action through
  # `Ezagent.Invocation.dispatch/1` so caps gate at step 5.5 +
  # workspace isolation at step 5.6. The ring + cursor + subscriber
  # bookkeeping lives in `Ezagent.Behavior.Publisher.SessionImpl`.
  # ─────────────────────────────────────────────────────────────────────

  alias Ezagent.Behavior.Publisher.SessionFacade

  @impl Ezagent.Behavior.Publisher
  def history_retention, do: 100

  @impl Ezagent.Behavior.Publisher
  def subscribe_from(%URI{} = _publisher_uri, subscriber_pid, _cursor)
      when is_pid(subscriber_pid),
      do: SessionFacade.raise_no_ambient_caps!(__MODULE__, :subscribe_from, 4)

  @impl Ezagent.Behavior.Publisher
  def snapshot(%URI{} = _publisher_uri),
    do: SessionFacade.raise_no_ambient_caps!(__MODULE__, :snapshot, 2)

  @impl Ezagent.Behavior.Publisher
  def history(%URI{} = _publisher_uri, _from, _to),
    do: SessionFacade.raise_no_ambient_caps!(__MODULE__, :history, 4)

  @spec subscribe_from(URI.t(), pid(), Ezagent.Behavior.Publisher.cursor(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate subscribe_from(publisher_uri, subscriber_pid, cursor, ctx), to: SessionFacade

  @spec snapshot(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate snapshot(publisher_uri, ctx), to: SessionFacade

  @spec history(
          URI.t(),
          Ezagent.Behavior.Publisher.cursor(),
          Ezagent.Behavior.Publisher.cursor(),
          map()
        ) ::
          {:ok, [Ezagent.Publisher.Event.t()]} | {:error, term()}
  defdelegate history(publisher_uri, from, to, ctx), to: SessionFacade
end
