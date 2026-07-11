defmodule Mix.Tasks.Ezagent.Socialware.ReseedBuiltinsTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Ezagent.Socialware.{
    ConfigObject,
    ConfigPointer,
    ConfigStore,
    Definition,
    DefinitionRegistry
  }

  @orchestrator "orchestrator"

  defp system_ws, do: DefinitionRegistry.system_workspace_uri()
  defp subject, do: DefinitionRegistry.definition_subject_uri(system_ws(), @orchestrator)

  setup do
    # Clear the orchestrator subject inside the sandbox (boot commits built-ins).
    Repo.delete_all(from(p in ConfigPointer, where: p.subject_uri == ^subject()))
    Repo.delete_all(from(o in ConfigObject, where: o.subject_uri == ^subject()))
    Mix.Task.reenable("ezagent.socialware.reseed_builtins")
    :ok
  end

  defp seed_prior_cc! do
    {:ok, definition} =
      Definition.new(%{
        name: @orchestrator,
        title: "Orchestrator",
        description: "Stock cc orchestrator team front desk.",
        uses: ["cc"],
        roles: [%{role_name: @orchestrator, fill: :agent, recipe: @orchestrator, flavor: "cc"}],
        visibility_policy: %{publish_policy: :auto, web_anon_access: false}
      })

    {:ok, %{object: object}} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: system_ws(),
        subject_uri: subject(),
        key: DefinitionRegistry.definition_key(),
        body: Definition.body(definition),
        actor_uri: "entity://system/user/admin",
        source_turn_id: "legacy-seed:#{System.unique_integer([:positive])}"
      })

    object
  end

  defp stored_flavor do
    {:ok, definition, _} = DefinitionRegistry.lookup(system_ws(), @orchestrator)
    [role | _] = definition.roles
    role.flavor
  end

  test "default (no --force) reports the divergence and does NOT overwrite" do
    old = seed_prior_cc!()

    capture_io(fn ->
      Mix.Task.rerun("ezagent.socialware.reseed_builtins", [@orchestrator])
    end)

    # stored definition untouched — still cc
    assert stored_flavor() == "cc"
    {:ok, _def, object} = DefinitionRegistry.lookup(system_ws(), @orchestrator)
    assert object.id == old.id
  end

  test "--force applies the code version (cc-deepseek)" do
    seed_prior_cc!()

    capture_io(fn ->
      Mix.Task.rerun("ezagent.socialware.reseed_builtins", [@orchestrator, "--force"])
    end)

    assert stored_flavor() == "cc-deepseek"
  end

  test "--force on an unknown name fails loud" do
    assert_raise Mix.Error, ~r/no built-in socialware definition named/, fn ->
      capture_io(fn ->
        Mix.Task.rerun("ezagent.socialware.reseed_builtins", ["does-not-exist", "--force"])
      end)
    end
  end
end
