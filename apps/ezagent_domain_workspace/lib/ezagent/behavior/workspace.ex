defmodule Ezagent.Behavior.Workspace do
  @moduledoc """
  Workspace Behavior — declarative cluster-shape state for the
  Workspace Kind (Phase 4 D3/D5).

  ## State slice (`:workspace`)

      %{
        members: MapSet.t(URI.t()),
        # session templates: name → %{members: [URI], routing_rules: [map]}
        session_templates: %{String.t() => map()},
        routing_rules: [map()]
      }

  ## Actions

  - `:list_members` — `{:ok, slice, %{members: [URI]}}`
  - `:add_member` — args `%{member: URI}` → adds to MapSet
  - `:remove_member` — args `%{member: URI}` → removes from MapSet
  - `:list_templates` — `{:ok, slice, %{templates: map()}}`
  - `:add_template` — args `%{name: String, template: map}` → put in map
  - `:remove_template` — args `%{name: String}` → drop from map
  - `:list_routing_rules` — `{:ok, slice, %{rules: [map]}}`
  - `:set_routing_rules` — args `%{rules: [map]}` → replace list
  - `:instantiate` — returns the children list this Workspace declares:
    `{:ok, slice, %{children: [{kind_module, args_map, uri}]}}`.
    The caller (Phase 4c `Ezagent.Workspace.Loader`) walks the list and
    spawns each via plugin-registered spawn functions.

  ## Why `:instantiate` returns data, not side-effects

  Plugin isolation: `ezagent_core` does not know which plugin owns which
  Kind's supervisor. The Workspace Kind itself stays plugin-agnostic
  by returning the declared shape; the Loader injects the spawn
  policy (DI at the boundary, per the north star).

  Phase 4b: only members are translated to children (each member URI
  becomes a child to spawn). Session templates and routing rules are
  carried in state but not yet materialized — Phase 4c wires them.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions do
    [
      :list_members,
      :add_member,
      :remove_member,
      :list_templates,
      :add_template,
      :remove_template,
      :list_routing_rules,
      :set_routing_rules,
      :instantiate
    ]
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:list_members, "list members (user URIs) of this workspace"},
      {:add_member, "add a user URI to this workspace's member set"},
      {:remove_member, "remove a user URI from this workspace's member set"},
      {:list_templates,
       "list templates (SessionTemplate / AgentTemplate) bound to this workspace"},
      {:add_template, "bind a template version to this workspace"},
      {:remove_template, "unbind a template from this workspace"},
      {:list_routing_rules, "list workspace-scoped routing rules"},
      {:set_routing_rules, "replace the workspace's routing rule set"},
      {:instantiate, "instantiate a fresh workspace from a workspace template"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :workspace

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      members: read_members(args),
      session_templates: Map.get(args, :session_templates, %{}),
      routing_rules: Map.get(args, :routing_rules, [])
    }
  end

  defp read_members(args) do
    case Map.get(args, :members) do
      nil -> MapSet.new()
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
    end
  end

  # --- members ---------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:list_members, slice, _args, _ctx) do
    {:ok, slice, %{members: MapSet.to_list(slice.members)}}
  end

  def invoke(:add_member, slice, %{member: %URI{} = uri}, _ctx) do
    {:ok, %{slice | members: MapSet.put(slice.members, uri)}}
  end

  def invoke(:remove_member, slice, %{member: %URI{} = uri}, _ctx) do
    {:ok, %{slice | members: MapSet.delete(slice.members, uri)}}
  end

  # --- session templates ----------------------------------------------

  def invoke(:list_templates, slice, _args, _ctx) do
    {:ok, slice, %{templates: slice.session_templates}}
  end

  def invoke(:add_template, slice, %{name: name, template: tmpl}, _ctx)
      when is_binary(name) and is_map(tmpl) do
    {:ok, %{slice | session_templates: Map.put(slice.session_templates, name, tmpl)}}
  end

  def invoke(:remove_template, slice, %{name: name}, _ctx) when is_binary(name) do
    {:ok, %{slice | session_templates: Map.delete(slice.session_templates, name)}}
  end

  # --- routing rules ---------------------------------------------------

  def invoke(:list_routing_rules, slice, _args, _ctx) do
    {:ok, slice, %{rules: slice.routing_rules}}
  end

  def invoke(:set_routing_rules, slice, %{rules: rules}, _ctx) when is_list(rules) do
    {:ok, %{slice | routing_rules: rules}}
  end

  # --- instantiate (the north-star action) -----------------------------

  def invoke(:instantiate, slice, _args, _ctx) do
    # Phase 4-completion: emit both member spawns and template
    # instantiations. Loader walks each child tuple and dispatches to
    # SpawnRegistry (members) or TemplateRegistry (templates).
    # Members ordered first so any Session-Template member dependencies
    # are already alive when chat/join fires (cast + PendingDelivery
    # makes this not strictly necessary but reduces inbox noise).
    member_children =
      slice.members
      |> Enum.map(fn %URI{} = uri -> {:member, uri} end)

    template_children =
      slice.session_templates
      |> Enum.map(fn {tmpl_name, tmpl_data} ->
        {:template, tmpl_name, tmpl_data}
      end)

    {:ok, slice, %{children: member_children ++ template_children}}
  end

  # --- interface (adapter generation + arg validation) ----------------

  @impl Ezagent.Behavior
  def interface do
    %{
      list_members: %{
        description: "List the workspace's member URIs",
        args: %{},
        returns: %{members: {:list, :uri}},
        modes: [:call]
      },
      add_member: %{
        description: "Add an entity URI to the workspace's member set",
        args: %{member: :uri},
        returns: %{},
        modes: [:cast, :call]
      },
      remove_member: %{
        description: "Remove an entity URI from the workspace's member set",
        args: %{member: :uri},
        returns: %{},
        modes: [:cast, :call]
      },
      list_templates: %{
        description: "List the workspace's session templates",
        args: %{},
        returns: %{templates: :map},
        modes: [:call]
      },
      add_template: %{
        description: "Add or replace a named session template",
        args: %{name: :string, template: :map},
        returns: %{},
        modes: [:cast, :call]
      },
      remove_template: %{
        description: "Remove a named session template",
        args: %{name: :string},
        returns: %{},
        modes: [:cast, :call]
      },
      list_routing_rules: %{
        description: "List the workspace's routing rules",
        args: %{},
        returns: %{rules: {:list, :map}},
        modes: [:call]
      },
      set_routing_rules: %{
        description: "Replace the workspace's routing rule list",
        args: %{rules: {:list, :map}},
        returns: %{},
        modes: [:cast, :call]
      },
      instantiate: %{
        description: "Return the child entities + templates this workspace declares",
        args: %{},
        returns: %{children: {:list, :tuple}},
        modes: [:call]
      }
    }
  end
end
