defmodule EzagentPluginCustomerChat.SessionViewLiveTakeoverTest do
  @moduledoc """
  Phase 2.6 wiring — the operator console's "Take over" button must
  dispatch `mode.set` with args that conform to the REAL
  `Ezagent.Behavior.Mode` `:set` action schema.

  `Behavior.Mode` (PR #511) declares `action :set, args: %{mode: :atom}`,
  so the LiveView's dispatch args must be exactly `%{mode: :takeover}`.
  The pre-2.6 placeholder shipped an extra `:set_by` key (a best-guess
  before Mode existed); the takeover handler silently mismatched the
  real schema. This is a contract test rather than a full live-session
  integration test because the proven live-session setup (Repo sandbox +
  WorkspaceRegistry bind + Kind.spawn + AgentBridge adapter) lives in
  `ezagent_domain_chat/test/support` and is not compiled into this
  plugin's test env — replicating it would touch far more than the
  takeover fix. Instead we pin the LiveView's args against Mode's own
  declared schema (single source of truth), which catches exactly the
  stray-key regression this fix removes.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginCustomerChat.SessionViewLive
  alias Ezagent.Behavior.Mode

  test "takeover_args/0 is exactly %{mode: :takeover}" do
    assert SessionViewLive.takeover_args() == %{mode: :takeover}
  end

  test "takeover_args/0 keys match Behavior.Mode's declared :set action schema" do
    # Single source of truth: Mode declares `action :set, args: %{mode: :atom}`.
    set_schema = Mode.__actions__()[:set].args
    assert set_schema == %{mode: :atom}

    # The LiveView must send EXACTLY the keys Mode's :set action declares —
    # no extras (the pre-2.6 placeholder leaked a `:set_by` key). Equal key
    # sets prove the dispatch will not be rejected for an unexpected arg.
    assert Map.keys(SessionViewLive.takeover_args()) == Map.keys(set_schema)
  end

  test "takeover_args/0 values satisfy the declared :set arg types" do
    set_schema = Mode.__actions__()[:set].args

    Enum.each(SessionViewLive.takeover_args(), fn {key, value} ->
      case Map.fetch!(set_schema, key) do
        :atom -> assert is_atom(value), "expected #{inspect(key)} to be an atom"
        other -> flunk("unexpected declared type #{inspect(other)} for #{inspect(key)}")
      end
    end)
  end

  test "takeover_args/0 selects a mode Behavior.Mode actually supports" do
    # :takeover must be one of the modes handle_set/2 accepts (defends
    # against a typo'd mode atom that would dispatch but return
    # {:error, {:unsupported_mode, _}}).
    %{mode: mode} = SessionViewLive.takeover_args()
    assert {:ok, %{mode: ^mode}, [{:set, :mode, ^mode}]} =
             Mode.handle_set(%{mode: mode}, %{
               read: fn _key, default -> default end,
               self_uri: :not_a_session
             })
  end
end
