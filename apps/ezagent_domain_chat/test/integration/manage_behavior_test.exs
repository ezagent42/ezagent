defmodule EzagentDomainChat.Integration.ManageBehaviorTest do
  @moduledoc """
  PR-5b (#533 §3.4/§3.5) — the uniform `Ezagent.Behavior.Manage` surface:
  registered on every Kind, `:delete` tears down via `Lifecycle.destroy`,
  `:reconfigure` is the immutable-default until the Template-Class registry
  (PR-5e) provides per-Class hooks.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Manage
  alias Ezagent.CapabilityRegistry
  alias Ezagent.{KindRegistry, SpawnRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Session

  defp wait_until(fun, tries \\ 60)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")
  defp wait_until(fun, n), do: if(fun.(), do: :ok, else: (Process.sleep(20); wait_until(fun, n - 1)))

  describe "the Manage behavior surface" do
    test "exposes :delete and :reconfigure" do
      assert :delete in Manage.actions()
      assert :reconfigure in Manage.actions()
    end

    test "required_caps gate both actions with cap(:any, Manage, :any)" do
      caps = Manage.required_caps()
      expected = Ezagent.Capability.cap(:any, Manage, :any)
      assert caps[:delete] == expected
      assert caps[:reconfigure] == expected
    end

    test "reconfigure is unsupported by default — surfaces a dispatch error (immutable Kind until PR-5e)" do
      assert {:error, :reconfigure_unsupported} =
               Manage.handle_reconfigure(%{template_data: %{}}, %{})
    end

    test "handle_delete returns a deferred schedule_delete effect carrying self_uri" do
      uri = Ezagent.URI.new!("session://default/system/mg-#{System.unique_integer([:positive])}")

      assert {:ok, {:ok, :deleted}, effects} = Manage.handle_delete(%{}, %{self_uri: uri})
      assert {:effect, {Manage, :schedule_delete}, [^uri]} = Enum.find(effects, &match?({:effect, {Manage, :schedule_delete}, _}, &1))
    end
  end

  describe "universal registration — every Kind by construction (§3.4, decision 1-B)" do
    # Includes core/domain Kinds AND plugin Kinds (CurlAgent — the codex P2
    # gap) AND an arbitrary never-registered module: Manage resolves for all
    # via the UniversalBehaviors fallback, with NO per-Kind registration.
    @kinds [
      Ezagent.Entity.Session,
      Ezagent.Entity.Agent,
      Ezagent.Entity.User,
      Ezagent.Entity.Workspace,
      Ezagent.Entity.System,
      Ezagent.Entity.AgentTemplate,
      Ezagent.Entity.SessionTemplate,
      Ezagent.Entity.CurlAgent,
      Ezagent.NeverRegisteredFakeKind
    ]

    test "lookup_subject resolves Manage :delete + :reconfigure for every Kind" do
      for kind <- @kinds, action <- [:delete, :reconfigure] do
        assert {:ok, %{behavior: Ezagent.Behavior.Manage}} =
                 CapabilityRegistry.lookup_subject(kind, action),
               "Manage #{action} did not resolve for #{inspect(kind)}"
      end
    end

    test "BehaviorRegistry.lookup resolves Manage (dispatch handler) for every Kind" do
      for kind <- @kinds, action <- [:delete, :reconfigure] do
        assert {:ok, Ezagent.Behavior.Manage} =
                 Ezagent.BehaviorRegistry.lookup(kind, action),
               "Manage #{action} dispatch handler did not resolve for #{inspect(kind)}"
      end
    end

    test "non-manage actions are unaffected by the universal fallback" do
      assert :error = Ezagent.BehaviorRegistry.lookup(Ezagent.NeverRegisteredFakeKind, :some_random_action)
      assert :error = CapabilityRegistry.lookup_subject(Ezagent.NeverRegisteredFakeKind, :some_random_action)
    end
  end

  describe ":delete tears the Kind down (via Lifecycle.destroy)" do
    test "schedule_delete destroys a live durable Session (process gone + snapshot cleared)" do
      uri =
        Ezagent.URI.new!("session://default/team-alpha/mg-del-#{System.unique_integer([:positive])}")

      uri_str = URI.to_string(uri)
      {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: uri})
      wait_until(fn -> match?({:ok, _}, KindRegistry.lookup(uri)) end)
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)

      :ok = Manage.schedule_delete(uri)

      # The detached task sleeps ~20ms then runs Lifecycle.destroy
      # (terminate → snapshot+marker clear).
      wait_until(fn -> KindRegistry.lookup(uri) == :error end)
      wait_until(fn -> is_nil(KindSnapshot.get(uri_str)) end)

      # And it does NOT resurrect via ensure_live (row gone → not_created).
      assert {:error, :not_created} = SpawnRegistry.ensure_live(uri)
    end
  end
end
