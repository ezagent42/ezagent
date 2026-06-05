# Adding a Kind, Behavior, or Template Class

Ezagent has three primitives plugin authors compose: **Kind** (process identity + lifecycle), **Behavior** (action interface + slice state), **Template Class** (declarative spawn of one or more Kinds). This doc walks through adding each, with concrete examples.

If you're adding a whole new plugin (not just a Kind inside an existing plugin), read `docs/onboarding/adding-a-plugin.md` first — this doc assumes the plugin scaffolding exists.

## Concept refresher

- **Kind** = a process *type*. Identified by URI scheme + module. E.g. `:user` Kind, URIs like `user://alice`. Implements `Ezagent.Kind` behaviour (callbacks `type_name/0`, `behaviors/0`, `persistence/0`).
- **Behavior** = an action interface + a slice schema. One Behavior module can be attached to many Kinds via `BehaviorRegistry.register(kind, action, behavior)`. E.g. `Ezagent.Behavior.Chat` provides `:send` / `:join` / `:leave` for Session Kind; `:receive` for User + Agent Kinds.
- **Template Class** = a spawn-from-config recipe. Implements `Ezagent.Kind.Template` behaviour with callbacks `template_name/0`, `validate/1`, `instantiate/3`. The Workspace plugin (and now PR 38's SessionTemplate) uses these for declarative session creation.

The composition: a Kind's lifecycle is run by `Ezagent.Kind.Server` (in core); its `behaviors/0` callback lists which Behaviors initialize slices; per-Kind `BehaviorRegistry.register` decides which actions dispatch to which Behavior.

## Add a Kind

### Step 1 — module

`apps/<your_domain>/lib/<your>/entity/<your_kind>.ex`:

```elixir
defmodule Ezagent.Entity.MyKind do
  @moduledoc """
  MyKind — what it represents in Ezagent's process model.

  URI scheme: `mykind://<authority>` (or whatever convention).
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :my_kind

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Identity]   # which Behaviors' init_slice run at boot

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}   # or :ephemeral / :on_terminate
end
```

### Step 2 — spawn fn

Register a spawn fn for your URI scheme in the plugin's `Application.start/2`:

```elixir
:ok = Ezagent.SpawnRegistry.register("mykind", fn uri ->
  DynamicSupervisor.start_child(
    MyPlugin.MyKindSupervisor,
    {Ezagent.Kind.Server, {Ezagent.Entity.MyKind, %{uri: uri}}}
  )
end)
```

**Constraint** (Decision #65): spawn fn takes the URI only — no per-Kind init args plumbed through `SpawnRegistry`. If your Kind needs initialization data, the pattern is: spawn it (slice initializes empty), then dispatch a setup action to populate the slice. See `Ezagent.WorkspaceRegistry.bind` for an analogous lookup-table pattern that avoids spawn-time args.

### Step 3 — supervisor

Add the DynamicSupervisor to your plugin's children list:

```elixir
children = [
  {DynamicSupervisor, name: MyPlugin.MyKindSupervisor, strategy: :one_for_one},
  # ...
]
```

### Step 4 — test

```elixir
defmodule Ezagent.Entity.MyKindTest do
  use ExUnit.Case, async: true

  alias Ezagent.Entity.MyKind

  test "type_name/0 returns :my_kind" do
    assert MyKind.type_name() == :my_kind
  end

  test "persistence/0 matches design" do
    assert MyKind.persistence() == {:snapshot, :on_change}
  end

  test "all Ezagent.Kind callbacks implemented" do
    assert function_exported?(MyKind, :type_name, 0)
    assert function_exported?(MyKind, :behaviors, 0)
    assert function_exported?(MyKind, :persistence, 0)
  end
end
```

Reference: `apps/ezagent_domain_instance_message/lib/esr/entity/agent_template.ex` (Phase 7 PR 37, simplest recent example).

## Add a Behavior

### Step 1 — module

`apps/<your_domain>/lib/<your>/behavior/<your_behavior>.ex`:

```elixir
defmodule Ezagent.Behavior.MyBehavior do
  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def state_slice, do: :my_slice

  @impl Ezagent.Behavior
  def init_slice(_args) do
    %{
      # Whatever shape your Behavior maintains
      counter: 0
    }
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      bump: %{
        args: %{by: :integer},
        returns: %{new_value: :integer},
        modes: [:call, :cast]
      }
    }
  end

  @impl Ezagent.Behavior
  def invoke(:bump, slice, %{by: n}, _ctx) do
    new_slice = %{slice | counter: slice.counter + n}
    {:ok, new_slice, %{new_value: new_slice.counter}}
  end
end
```

### Step 2 — register per-Kind

In your plugin's `register_behaviors`:

```elixir
:ok = Ezagent.BehaviorRegistry.register(Ezagent.Entity.MyKind, :bump, Ezagent.Behavior.MyBehavior)
```

A Behavior can be registered on multiple Kinds with different action subsets per Kind. `Ezagent.Behavior.Chat` does this — Session gets `:send / :join / :leave`, User + Agent get `:receive`.

### Step 3 — test

```elixir
defmodule Ezagent.Behavior.MyBehaviorTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.MyBehavior

  test "init_slice/1 returns expected shape" do
    assert %{counter: 0} = MyBehavior.init_slice(%{})
  end

  test "invoke(:bump, ...) increments counter and returns new value" do
    slice = %{counter: 5}
    assert {:ok, new_slice, %{new_value: 8}} = MyBehavior.invoke(:bump, slice, %{by: 3}, %{})
    assert new_slice.counter == 8
  end

  test "interface declares :bump action" do
    interface = MyBehavior.interface()
    assert Map.has_key?(interface, :bump)
    assert interface[:bump].modes == [:call, :cast]
  end
end
```

Reference: `apps/ezagent_domain_instance_message/lib/esr/behavior/chat.ex` (most complex Behavior, well-commented).

## Add a Template Class

Template Classes are for declarative spawn. Workspace stores `session_templates` maps referencing Template Class names; SessionTemplate (PR 38) is itself a Template Class. To add your own:

### Step 1 — implement the behaviour

`apps/<your_domain>/lib/<your>/template/<your_class>.ex`:

```elixir
defmodule Ezagent.Template.MyClass do
  @moduledoc """
  Template Class for spawning a <whatever> from configuration data.
  """

  @behaviour Ezagent.Kind.Template

  @impl Ezagent.Kind.Template
  def template_name, do: "myplugin.myclass.standard"

  @impl Ezagent.Kind.Template
  def validate(template_data) do
    # Pre-persist schema check. Return :ok or {:error, _}.
    case Map.get(template_data, "name") do
      nil -> {:error, :missing_name}
      _ -> :ok
    end
  end

  @impl Ezagent.Kind.Template
  def instantiate(template_name, template_data, workspace_uri) do
    # Effectful spawn. MUST be idempotent (re-call returns same URIs).
    uri = URI.new!("mykind://#{template_data["name"]}")

    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} ->
        # IMPORTANT (invariant 4): if you spawned sessions, bind them.
        # Not relevant for non-session URIs.
        {:ok, [uri]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### Step 2 — register in plugin Application.start

```elixir
:ok = Ezagent.TemplateRegistry.register(Ezagent.Template.MyClass)
```

`TemplateRegistry.register/1` reads `template_name/0` itself. Strict-duplicate: if another plugin already registered the same name, returns `{:error, {:duplicate, existing, attempted}}`. Pick a unique name (prefix with your plugin name).

### Step 3 — test

```elixir
defmodule Ezagent.Template.MyClassTest do
  use ExUnit.Case, async: false

  alias Ezagent.Template.MyClass

  test "template_name/0 stable id" do
    assert MyClass.template_name() == "myplugin.myclass.standard"
  end

  test "validate/1 rejects missing name" do
    assert {:error, :missing_name} = MyClass.validate(%{})
  end

  test "validate/1 accepts name" do
    assert :ok = MyClass.validate(%{"name" => "test"})
  end

  test "instantiate/3 spawns + returns URI list" do
    workspace_uri = URI.new!("workspace://test-#{System.unique_integer([:positive])}")
    template_data = %{"name" => "instance-#{System.unique_integer([:positive])}"}

    assert {:ok, [uri]} = MyClass.instantiate("tmpl-name", template_data, workspace_uri)
    assert uri.scheme == "mykind"
  end

  test "instantiate/3 idempotent — second call returns same URI" do
    workspace_uri = URI.new!("workspace://test-#{System.unique_integer([:positive])}")
    template_data = %{"name" => "instance-#{System.unique_integer([:positive])}"}

    assert {:ok, [uri1]} = MyClass.instantiate("tmpl-name", template_data, workspace_uri)
    assert {:ok, [uri2]} = MyClass.instantiate("tmpl-name", template_data, workspace_uri)
    assert URI.to_string(uri1) == URI.to_string(uri2)
  end
end
```

Reference: `apps/ezagent_domain_instance_message/lib/esr/template/generic_session.ex`.

## How to write an invariant test

Invariant tests are CI gates for architectural rules — they FAIL when a future PR re-introduces a violation. They drive the production code path (not direct function calls) and assert via observable side-effects (audit log, message_routings, PubSub broadcast received).

**Canonical pattern** (from `apps/ezagent_domain_instance_message/test/integration/workspace_isolation_test.exs`):

1. `use EzagentCore.DataCase, async: false` (persistence + dispatch + sandbox)
2. Spawn the production setup: `Ezagent.SpawnRegistry.spawn(uri)`, `WorkspaceRegistry.bind`, `RuleStore.add` — NOT mock objects
3. Drive `Ezagent.Invocation.dispatch` — NOT direct module calls
4. Assert via audit log (`invocations` table), message store, or message_routings — NOT internal slice state
5. Name the file `<invariant>_test.exs` (discoverable)
6. Tag `:slow` if it spawns OS subprocesses (CI runs `--include slow`)

Write the failure message so a future debugger immediately understands what was violated. Something like:

```elixir
assert eavesdropper_received? == false,
       "workspace-A-scoped rule fired for workspace-B message — " <>
         "workspace isolation broken (Decision #135 violated)"
```

Cite the Decision Log entry in the failure message. The next person to fail this test should be able to grep for it.

## When you're done

- Run your new test
- Run the cross-PR invariant suite (per `docs/onboarding/first-30-days.md` §week-4)
- Update `GLOSSARY.md` if your Kind/Behavior introduces a new term
- Update `.claude/skills/esr-developer/SKILL.md` if your change introduces a new pattern or anti-pattern
- SPEC_REVIEW 8-item checklist (per `docs/phase-specs/phase7/SPEC.md` §SPEC_REVIEW walkthrough)
- Open PR with the checklist in the body

The skill update is especially important — it's how future contributors discover your work. The skill is the dev team's "Allen replacement" for architectural judgment (Decision #140).
