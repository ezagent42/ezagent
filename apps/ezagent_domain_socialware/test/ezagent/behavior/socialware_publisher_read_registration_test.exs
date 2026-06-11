defmodule Ezagent.Behavior.SocialwarePublisherReadRegistrationTest do
  @moduledoc """
  P3-3 registration / single-owner GATE (boots the real domain apps).

  Proves the dispatch wiring that closes the chat-publisher widening:

  - `{SocialwareSession, :snapshot|:history} -> SocialwarePublisherRead`
    is registered (these reads dispatch to the socialware read behavior).
  - There is NO `{SocialwareSession, :snapshot|:history|:subscribe_from}
    -> Publisher.SessionImpl` registration (the chat publisher's read
    actions are registered ONLY against the chat `Session` Kind — so a
    chat `kind: :session, behavior: Publisher.SessionImpl` cap can never
    dispatch a read on a `SocialwareSession`).
  - `SocialwarePublisherRead` declares NO `:subscribe_from` action, so the
    streaming-leak class is impossible by construction.
  - Exactly ONE behavior on `SocialwareSession` OWNS (materializes) the
    `:publisher` slice — the trunk `Publisher.SessionImpl`. The read
    behavior is registry-only (NOT in `behaviors/0`) and does not
    materialize the slice.
  """

  use ExUnit.Case, async: false

  alias Ezagent.BehaviorRegistry, as: BR
  alias Ezagent.Behavior.{Publisher, SocialwarePublisherRead}
  alias Ezagent.Entity.{Session, SocialwareSession}

  setup_all do
    Code.ensure_loaded!(SocialwareSession)
    Code.ensure_loaded!(SocialwarePublisherRead)
    Code.ensure_loaded!(Publisher.SessionImpl)
    :ok
  end

  test "socialware read actions dispatch to SocialwarePublisherRead" do
    assert BR.lookup(SocialwareSession, :snapshot) == {:ok, SocialwarePublisherRead}
    assert BR.lookup(SocialwareSession, :history) == {:ok, SocialwarePublisherRead}
  end

  test "NO Publisher.SessionImpl read action is registered on SocialwareSession (widening closed)" do
    for action <- [:snapshot, :history, :subscribe_from] do
      case BR.lookup(SocialwareSession, action) do
        {:ok, mod} ->
          refute mod == Publisher.SessionImpl,
                 "#{action} on SocialwareSession must NOT resolve to Publisher.SessionImpl"

        :error ->
          :ok
      end
    end
  end

  test "subscribe_from is NOT dispatchable on SocialwareSession (deferred — no streaming leak)" do
    assert BR.lookup(SocialwareSession, :subscribe_from) == :error
    refute :subscribe_from in SocialwarePublisherRead.actions()
  end

  test "the chat Session keeps its OWN Publisher.SessionImpl read registration (unchanged)" do
    assert BR.lookup(Session, :snapshot) == {:ok, Publisher.SessionImpl}
    assert BR.lookup(Session, :history) == {:ok, Publisher.SessionImpl}
    assert BR.lookup(Session, :subscribe_from) == {:ok, Publisher.SessionImpl}
  end

  test "exactly ONE behavior on SocialwareSession materializes the :publisher slice" do
    publisher_owners =
      SocialwareSession
      |> Ezagent.Kind.behaviors_of()
      |> Enum.filter(fn b -> b.state_slice() == :publisher end)

    assert publisher_owners == [Publisher.SessionImpl],
           "expected exactly one :publisher owner (the trunk), got #{inspect(publisher_owners)}"

    # The read behavior is registry-only — it declares state_slice :publisher
    # to READ the trunk, but is NOT in behaviors/0 (so it never materializes).
    refute SocialwarePublisherRead in Ezagent.Kind.behaviors_of(SocialwareSession)
    assert SocialwarePublisherRead.state_slice() == :publisher
  end
end
