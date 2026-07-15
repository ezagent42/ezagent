defmodule Ezagent.Identity.CapReconcilerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.CapReconciler

  defmodule ReissuePolicy do
    @behaviour Ezagent.Cap.ReissuePolicy

    @impl true
    def classify(%Ezagent.Capability{behavior: __MODULE__}), do: {:ok, :test_reissue}
    def classify(_cap), do: :not_mine

    @impl true
    def reissue_action(_cap, _receiver),
      do: {:reissue, {:genesis, Ezagent.Entity.User.admin_uri()}}
  end

  defmodule BindingPolicy do
    @behaviour Ezagent.Cap.ReissuePolicy

    @impl true
    def classify(%Ezagent.Capability{behavior: __MODULE__}), do: {:ok, :test_binding}
    def classify(_cap), do: :not_mine

    @impl true
    def reissue_action(_cap, receiver), do: {:refresh_binding, {:agent, receiver}}
  end

  defmodule BrokenPolicy do
    @behaviour Ezagent.Cap.ReissuePolicy

    @impl true
    def classify(%Ezagent.Capability{behavior: __MODULE__}), do: {:ok, :test_broken}
    def classify(_cap), do: :not_mine

    @impl true
    def reissue_action(_cap, _receiver), do: {:error, :authority_missing}
  end

  setup do
    receiver =
      Ezagent.URI.new!("entity://team-alpha/user/reconcile-#{System.unique_integer([:positive])}")

    %{receiver: receiver}
  end

  test "partitions signed, reissuable, refresh-binding, and unknown caps", %{receiver: receiver} do
    signed = Ezagent.Test.CapHelper.issue!(receiver, raw_cap(ReissuePolicy))
    reissue = raw_cap(ReissuePolicy)
    refresh = raw_cap(BindingPolicy)
    unknown = raw_cap(__MODULE__.Unknown)

    plan =
      CapReconciler.plan(
        [signed, reissue, refresh, unknown],
        receiver,
        [ReissuePolicy, BindingPolicy]
      )

    assert plan.keep == [signed]

    assert [
             %{cap: ^reissue, class: :test_reissue, action: {:reissue, _}},
             %{
               cap: ^refresh,
               class: :test_binding,
               action: {:refresh_binding, {:agent, ^receiver}}
             }
           ] = plan.reissue

    assert [%{cap: ^unknown, class: :unknown, reason: :no_resolver}] = plan.quarantine
  end

  test "never mistakes a dual-read legacy cap for signed", %{receiver: receiver} do
    legacy = raw_cap(ReissuePolicy)

    assert Ezagent.Cap.verify_for(legacy, receiver)
    refute Ezagent.Cap.signed_and_valid?(legacy, receiver)

    plan = CapReconciler.plan([legacy], receiver, [ReissuePolicy])

    assert plan.keep == []
    assert [%{cap: ^legacy, class: :test_reissue}] = plan.reissue
  end

  test "resolver errors quarantine instead of blind-signing", %{receiver: receiver} do
    legacy = raw_cap(BrokenPolicy)

    plan = CapReconciler.plan([legacy], receiver, [BrokenPolicy])

    assert plan.keep == []
    assert plan.reissue == []

    assert [%{cap: ^legacy, class: :test_broken, reason: {:policy_error, :authority_missing}}] =
             plan.quarantine
  end

  defp raw_cap(behavior) do
    %Ezagent.Capability{
      kind: :user,
      behavior: behavior,
      action: :read,
      instance: :any,
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end
end
