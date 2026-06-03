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

    test "reconfigure is unsupported by default (immutable Kind until PR-5e Class hooks)" do
      assert {:ok, {:error, :reconfigure_unsupported}, []} =
               Manage.handle_reconfigure(%{template_data: %{}}, %{})
    end

    test "handle_delete returns a deferred schedule_delete effect carrying self_uri" do
      uri = Ezagent.URI.new!("session://default/system/mg-#{System.unique_integer([:positive])}")

      assert {:ok, {:ok, :deleted}, effects} = Manage.handle_delete(%{}, %{self_uri: uri})
      assert {:effect, {Manage, :schedule_delete}, [^uri]} = Enum.find(effects, &match?({:effect, {Manage, :schedule_delete}, _}, &1))
    end
  end

  describe "registration on every Kind (§3.4)" do
    test "Manage :delete + :reconfigure resolve on Session, Agent, User, Workspace, System, Templates" do
      kinds = [
        Ezagent.Entity.Session,
        Ezagent.Entity.Agent,
        Ezagent.Entity.User,
        Ezagent.Entity.Workspace,
        Ezagent.Entity.System,
        Ezagent.Entity.AgentTemplate,
        Ezagent.Entity.SessionTemplate
      ]

      for kind <- kinds, action <- [:delete, :reconfigure] do
        assert {:ok, _subject} = CapabilityRegistry.lookup_subject(kind, action),
               "Manage #{action} not registered on #{inspect(kind)}"
      end
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
