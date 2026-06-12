defmodule Ezagent.Behavior.SocialwarePublisherReadRegistrationTest do
  @moduledoc """
  Publisher-read registration / single-owner GATE on the UNIFIED Session Kind
  (boots the real domain apps).

  P5-1b (socialware substrate collapse) — there is now ONE Session Kind,
  `Ezagent.Entity.Session`, whose `behaviors/0` is the chat+socialware union.
  The former standalone socialware-session Kind has been DELETED (P5-3); its
  action registrations were already removed from socialware's `application.ex`
  in P5-1b. So the publisher-read wiring this suite gates lives entirely on
  `Entity.Session`:

  - `{Session, :snapshot|:history} -> SocialwarePublisherRead` is registered
    (reads route to the membership-gated read behavior: cap-exempt + live
    owner/member check).
  - `{Session, :subscribe_from} -> Publisher.SessionImpl` (the cap-gated
    streaming trunk path) is UNCHANGED — and reads NEVER resolve to it.
  - `SocialwarePublisherRead` declares NO `:subscribe_from` action, so the
    streaming-leak class is impossible by construction.
  - Exactly ONE behavior in the socialware subset OWNS (materializes) the
    `:publisher` slice — the trunk `Publisher.SessionImpl`. The read behavior
    is registry-only (NOT in `behaviors/0`) and does not materialize the slice.
  """

  use ExUnit.Case, async: false

  alias Ezagent.BehaviorRegistry, as: BR
  alias Ezagent.Behavior.{Publisher, SocialwarePublisherRead}
  alias Ezagent.Entity.Session

  setup_all do
    Code.ensure_loaded!(Session)
    Code.ensure_loaded!(SocialwarePublisherRead)
    Code.ensure_loaded!(Publisher.SessionImpl)
    :ok
  end

  test "read actions on the unified Session dispatch to SocialwarePublisherRead" do
    assert BR.lookup(Session, :snapshot) == {:ok, SocialwarePublisherRead}
    assert BR.lookup(Session, :history) == {:ok, SocialwarePublisherRead}
  end

  test "reads on the unified Session never resolve to Publisher.SessionImpl (widening closed)" do
    for action <- [:snapshot, :history] do
      assert BR.lookup(Session, action) == {:ok, SocialwarePublisherRead},
             "#{action} must resolve to the membership-gated read, not the trunk"
    end
  end

  test "subscribe_from on the unified Session is the cap-gated trunk; the read behavior has none" do
    assert BR.lookup(Session, :subscribe_from) == {:ok, Publisher.SessionImpl}
    refute :subscribe_from in SocialwarePublisherRead.actions()
  end

  test "exactly ONE behavior in the socialware subset materializes the :publisher slice" do
    publisher_owners =
      Session.socialware_behaviors()
      |> Enum.filter(fn b -> b.state_slice() == :publisher end)

    assert publisher_owners == [Publisher.SessionImpl],
           "expected exactly one :publisher owner (the trunk), got #{inspect(publisher_owners)}"

    # The read behavior is registry-only — it declares state_slice :publisher to
    # READ the trunk, but is NOT in behaviors/0 (so it never materializes).
    refute SocialwarePublisherRead in Ezagent.Kind.behaviors_of(Session)
    assert SocialwarePublisherRead.state_slice() == :publisher
  end
end
