defmodule Ezagent.Entity.SocialwareSessionPublisherTest do
  @moduledoc """
  P0 (socialware substrate) — minimal trunk-only test.

  Proves the Publisher TRUNK is composed onto `SocialwareSession`:
  the `:publisher` slice exists on a spawned session AND a slice change
  to a NON-publisher slice (`:surface`, via a real `surface.put_version`
  dispatch) RECORDS into the publisher ring.

  It deliberately does NOT exercise any dispatchable publisher READ API
  (snapshot / history / subscribe_from). That read API + its cap boundary
  are P3 (ExternalAdapter consumer) work — see the spec/plan deferral note.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Invocation

  # `Ezagent.Kind.behaviors_of/1` gates on `function_exported?/3`, which under
  # Elixir 1.19 does NOT auto-load the target module. Force it loaded so the
  # introspection sees the `behaviors/0` callback (test-harness bind-point).
  setup_all do
    Code.ensure_loaded!(SocialwareSession)
    :ok
  end

  setup do
    # The SliceChange hook is OFF by default — enable it for this suite so
    # the non-publisher slice change propagates to the Publisher trunk.
    original = Application.get_env(:ezagent_core, :slice_change_hook)
    Application.put_env(:ezagent_core, :slice_change_hook, true)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:ezagent_core, :slice_change_hook)
      else
        Application.put_env(:ezagent_core, :slice_change_hook, original)
      end
    end)

    :ok
  end

  defp spawn_session do
    session_uri =
      Ezagent.URI.session(
        :team_alpha,
        :socialware,
        "publisher-trunk-#{System.unique_integer([:positive])}"
      )

    :ok = KindSnapshot.delete(URI.to_string(session_uri))
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session_uri})

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    session_uri
  end

  # Mutate the NON-publisher `:surface` slice via the real `surface.put_version`
  # dispatch path. Each call appends a new version → the slice ALWAYS differs
  # from prior → SliceChange fires → the publisher trunk records it.
  defp mutate_surface_slice(session_uri, turn_id) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=surface.put_version"),
      mode: :call,
      args: %{turn_id: turn_id, tree: %{type: "text", props: %{text: turn_id}}},
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp publisher_slice(session_uri) do
    {:ok, slice} = Ezagent.Kind.get_slice(session_uri, :publisher)
    slice
  end

  defp wait_until_cursor(session_uri, target, attempts \\ 50)

  defp wait_until_cursor(_session_uri, _target, 0),
    do: flunk("publisher cursor never reached target")

  defp wait_until_cursor(session_uri, target, attempts) when attempts > 0 do
    case publisher_slice(session_uri) do
      %{cursor: c} when c >= target ->
        :ok

      _ ->
        Process.sleep(20)
        wait_until_cursor(session_uri, target, attempts - 1)
    end
  end

  test "SocialwareSession composes Publisher.SessionImpl (the trunk)" do
    behaviors = Ezagent.Kind.behaviors_of(SocialwareSession)
    assert Ezagent.Behavior.Publisher.SessionImpl in behaviors

    slice_keys = Enum.map(behaviors, & &1.state_slice())
    assert :publisher in slice_keys
  end

  test "a spawned SocialwareSession has a :publisher slice" do
    session_uri = spawn_session()

    assert {:ok, %{ring: [], cursor: 0}} = Ezagent.Kind.get_slice(session_uri, :publisher)
  end

  test "a non-publisher slice change records into the publisher ring (trunk works)" do
    session_uri = spawn_session()

    assert {:ok, %{version: 1}} = mutate_surface_slice(session_uri, "t1")
    wait_until_cursor(session_uri, 1)

    slice = publisher_slice(session_uri)
    assert slice.cursor == 1
    assert [%{cursor: 1, slice_key: :surface}] = slice.ring
  end
end
