defmodule Ezagent.Kind.Template.PreStartTest do
  use ExUnit.Case, async: false

  alias Ezagent.Kind.Template.PreStart
  alias Ezagent.TestSupport.TemplatePreStartProbe

  setup do
    :ok = PreStart.replace_for_test(nil)
    Application.put_env(:ezagent_core, :template_pre_start_test_owner, self())

    on_exit(fn ->
      PreStart.replace_for_test(nil)
      Application.delete_env(:ezagent_core, :template_pre_start_test_owner)
      Application.delete_env(:ezagent_core, :template_pre_start_prepare_result)
      Application.delete_env(:ezagent_core, :template_pre_start_complete_result)
    end)

    :ok
  end

  test "missing implementation fails closed" do
    assert {:error, :template_pre_start_not_registered} = PreStart.prepare(%{opaque: :reference})
  end

  test "prepare returns a validated cwd and single-use completion claim" do
    :ok = PreStart.register(TemplatePreStartProbe)

    Application.put_env(
      :ezagent_core,
      :template_pre_start_prepare_result,
      {:ok, %{cwd: "/safe/task", claim: "implementation-claim"}}
    )

    reference = %{opaque: :reference}
    assert {:ok, %{cwd: "/safe/task", claim: claim}} = PreStart.prepare(reference)
    assert_receive {:pre_start_prepare, ^reference}

    assert :ok = PreStart.complete(claim, :ok)
    assert_receive {:pre_start_complete, "implementation-claim", :ok}
    assert {:error, :invalid_template_pre_start_claim} = PreStart.complete(claim, :ok)
    refute_receive {:pre_start_complete, _, _}
  end

  test "callbacks execute in callers without blocking the registry" do
    :ok = PreStart.register(TemplatePreStartProbe)
    owner = self()

    Application.put_env(:ezagent_core, :template_pre_start_prepare_result, fn ->
      send(owner, {:prepare_callback_pid, self()})

      receive do
        :release_prepare -> {:ok, %{cwd: "/safe/task", claim: :implementation_claim}}
      end
    end)

    caller = Task.async(fn -> PreStart.prepare(:opaque) end)
    assert_receive {:prepare_callback_pid, callback_pid}
    assert callback_pid == caller.pid

    assert :ok = PreStart.register(TemplatePreStartProbe)
    send(caller.pid, :release_prepare)
    assert {:ok, %{claim: claim}} = Task.await(caller)

    Application.put_env(:ezagent_core, :template_pre_start_complete_result, fn ->
      send(owner, {:complete_callback_pid, self()})
      :ok
    end)

    assert :ok = PreStart.complete(claim, :ok)
    assert_receive {:complete_callback_pid, callback_pid}
    assert callback_pid == self()
  end

  test "invalid implementation prepare results fail closed without creating a claim" do
    :ok = PreStart.register(TemplatePreStartProbe)
    Application.put_env(:ezagent_core, :template_pre_start_prepare_result, {:ok, %{cwd: ""}})

    assert {:error, :invalid_template_pre_start_result} = PreStart.prepare(:opaque)
    assert {:error, :invalid_template_pre_start_claim} = PreStart.complete(make_ref(), :ok)
  end

  test "generic contract contains no downstream product vocabulary" do
    source = File.read!("lib/ezagent/kind/template/pre_start.ex")

    for forbidden <- ["Git", "TaskWorkspace", "GitTaskAccess", "plugin_cc", "provider", "flavor"] do
      refute source =~ forbidden
    end
  end
end
