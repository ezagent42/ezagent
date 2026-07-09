defmodule Ezagent.World.SlotRegistry do
  @moduledoc """
  唯一真源(source of truth)of world's typed-slot contract.

  A *slot* is a renderer-agnostic catalog entry — `{type, renderer_family,
  data_source, category, title}` — NOT a React component. React renderers are
  one implementation of a renderer family; describing a slot by its data
  contract + family (not by a hardcoded TSX) is what makes the eventual
  world → `@json-render` convergence "swap the renderer," not "rewrite."

  Three slot categories resolve the "rendered outside the registry" ambiguity
  (handoff §2):

    * `:layout_slot` — a route-level slot. Every `WorldLive.route_for/2`
      component MUST be a registered `:layout_slot` here. These participate in
      the hard-fail layout gate; an unregistered route slot fails CI.
    * `:subcomponent` — owned and mounted by a parent surface (e.g. the members
      panel / routing view / composer inside `Conversation`, or the nested PTY
      inside a conversation). NOT route-mounted, NOT in this registry; marked in
      the DOM with `data-world-subcomponent` so the JS mount gate knows it is a
      sanctioned parent-owned mount, not a registry bypass.
    * `:shell` — universal chrome (sidebar / header / command palette). Lives
      outside the layout grid; enumerated in `shell_chrome/0` as the seed
      allowlist for the mount gate.

  This module is the SoT; `assets/src/slots.manifest.json` is a generated,
  checked-in projection of `manifest/0` that the React renderer + the JS mount
  gate consume. `mix world.slots.manifest` regenerates it and a sync test
  (`slot_manifest_test.exs`) fails on drift.
  """

  @manifest_version 1

  # renderer_family => {data_source, [{type, title}]}
  #
  # data_source is the Elixir origin of the slot's state shape (the renderer-
  # agnostic data contract): a `*Data` module, or `:world_live` when the state
  # is assembled inline in the LiveView. Keep this list in sync with
  # `main.tsx`'s renderer map and `WorldLive.route_for/2`.
  @families %{
    sessions: {:world_live, [{"sessions_table", "Sessions"}]},
    # Overview 操作员落地页（FP5 S2-a）：KPI 概览 + 快捷入口,数据复用 AdminData。
    overview: {Ezagent.World.AdminData, [{"overview", "Overview"}]},
    conversation: {Ezagent.World.ConversationData, [{"conversation", "Conversation"}]},
    pty: {:world_live, [{"pty_terminal", "Terminal"}]},
    layout_editor: {:layout, [{"layout_editor", "Layout"}]},
    admin:
      {Ezagent.World.AdminData,
       [
         {"dashboard", "Admin Dashboard"},
         {"observability", "Observability"},
         {"entity_registry", "Entity Registry"},
         {"snapshots", "Snapshots"},
         {"templates", "Templates"},
         {"caps_admin", "Capabilities"},
         {"authz_audit", "Authz Audit"},
         {"settings", "Settings"},
         {"routing", "Routing"},
         {"external_mirror", "External Mirror"}
       ]},
    workspace_plugins:
      {Ezagent.World.WorkspacePluginData,
       [
         {"workspaces_list", "Workspaces"},
         {"workspace_detail", "Workspace Detail"},
         {"workspace_template_new", "New Template"},
         {"plugins", "Plugins"},
         {"feishu_bindings", "Feishu Bindings"},
         {"auto_derive", "Auto Derive"},
         {"profile", "Profile"}
       ]},
    # kanban 操作面（kanban-as-role K4）—— 自有 renderer family + KanbanData。
    kanban: {Ezagent.World.KanbanData, [{"kanban", "看板"}]},
    identities:
      {Ezagent.World.IdentityData,
       [
         {"identities", "Identities"},
         {"users_table", "Users"},
         {"user_new_form", "New User"},
         {"user_detail", "User Detail"},
         {"agents_table", "Agents"},
         {"agent_new_form", "New Agent"},
         {"agent_detail", "Agent Detail"},
         {"entity_caps", "Entity Caps"},
         {"agent_api_keys", "Agent API Keys"},
         {"agent_extensions", "Agent Extensions"},
         {"agent_config", "Agent Config"}
       ]}
  }

  # Seed allowlist for the JS mount gate: universal shell chrome that mounts
  # outside the layout renderer by design. Identified by stable DOM ids /
  # class hooks in `main.tsx`. Adding to this list is the ONLY sanctioned way
  # to mount a top-level surface without going through the renderer, and each
  # entry must be justified here.
  @shell_chrome [
    # left activity/navigation rail
    "world-sidebar",
    # universal top header (title · scope · command launcher)
    "world-header",
    # ⌘K command palette dialog
    "world-cmdk"
  ]

  @type category :: :layout_slot | :subcomponent | :shell
  @type slot :: %{
          type: String.t(),
          title: String.t(),
          renderer_family: atom(),
          data_source: atom() | module(),
          category: category()
        }

  @doc "All `:layout_slot` specs, keyed by stable `type` string."
  @spec layout_slots() :: %{String.t() => slot()}
  def layout_slots do
    for {family, {data_source, types}} <- @families,
        {type, title} <- types,
        into: %{} do
      {type,
       %{
         type: type,
         title: title,
         renderer_family: family,
         data_source: data_source,
         category: :layout_slot
       }}
    end
  end

  @doc "The set of registered `:layout_slot` type strings."
  @spec layout_slot_types() :: MapSet.t(String.t())
  def layout_slot_types, do: layout_slots() |> Map.keys() |> MapSet.new()

  @doc "Look up a single slot spec by `type`, or `nil` if unregistered."
  @spec slot(String.t()) :: slot() | nil
  def slot(type) when is_binary(type), do: Map.get(layout_slots(), type)

  @doc "Is `type` a registered layout slot?"
  @spec layout_slot?(String.t()) :: boolean()
  def layout_slot?(type) when is_binary(type), do: Map.has_key?(layout_slots(), type)

  @doc "The renderer family atom for `type`, or `nil`."
  @spec renderer_family(String.t()) :: atom() | nil
  def renderer_family(type) when is_binary(type) do
    case slot(type) do
      %{renderer_family: family} -> family
      nil -> nil
    end
  end

  @doc "Seed allowlist of shell-chrome DOM hooks that mount outside the renderer."
  @spec shell_chrome() :: [String.t()]
  def shell_chrome, do: @shell_chrome

  @doc "The supported slot categories."
  @spec categories() :: [category()]
  def categories, do: [:layout_slot, :subcomponent, :shell]

  @doc """
  JSON-able projection of the registry — the SoT for the checked-in
  `assets/src/slots.manifest.json` consumed by the React renderer + JS gate.
  """
  @spec manifest() :: map()
  def manifest do
    slots =
      for {type, spec} <- layout_slots(), into: %{} do
        {type,
         %{
           "renderer_family" => Atom.to_string(spec.renderer_family),
           "category" => Atom.to_string(spec.category),
           "title" => spec.title,
           "data_source" => data_source_string(spec.data_source)
         }}
      end

    renderer_families =
      for {family, {_data_source, types}} <- @families, into: %{} do
        {Atom.to_string(family), Enum.map(types, fn {type, _title} -> type end) |> Enum.sort()}
      end

    %{
      "version" => @manifest_version,
      "categories" => Enum.map(categories(), &Atom.to_string/1),
      "renderer_families" => renderer_families,
      "slots" => slots,
      "shell_chrome" => @shell_chrome
    }
  end

  @doc "Pretty-printed manifest JSON with a trailing newline (the on-disk form)."
  @spec manifest_json() :: String.t()
  def manifest_json, do: Jason.encode!(manifest(), pretty: true) <> "\n"

  defp data_source_string(:world_live), do: "world_live"
  defp data_source_string(:layout), do: "layout"
  defp data_source_string(module) when is_atom(module), do: inspect(module)
end
