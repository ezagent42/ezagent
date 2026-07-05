defmodule EzagentPluginKanban.KanbanTeam do
  @moduledoc """
  The `socialware:kanban-team` Definition (S2) — a prewired team of a
  `pm-coordinator` (cc-headless coordinator), a `dev-together` (cc-headless
  developer running the copied dev-together skill), and a `kanban-manager`
  (native passive board actor). Published via code-seed (imperative
  `seed_definition_if_absent`, the hello `EzagentPluginHello.App` play), NOT a
  plugin package manifest (`core/manifest.ex` rejects a `:socialware` seed_ref by
  design). S3 adds the relay-back `routing_rules` + `legends` to this body.

  ## Zero instance URIs (role-slot #1180, enforced) + round-trip safety

  Participants are declared via the `roles` field as agent role-slots
  (`%{role_name, fill: :agent, recipe, flavor}` — all strings, `recipe` is a
  `RecipeRegistry` NAME resolved at materialize, never a URI). The three recipe
  names are exactly the ones the kanban plugin declares in
  `EzagentPluginKanban.Application.roles/0` (`kanban-manager` + the S1
  `pm-coordinator` / `dev-together`). The retired `agents`/`members` fields are
  rejected fail-loud by `Definition.new/1`
  (`definition.ex` `reject_retired_declaration_fields`), and any participant
  instance URI in `roles`/`routing_rules` is rejected too
  (`reject_participant_instance_uris`). `owner_policy` is `%{type: :installer}`
  (`:fixed` is rejected). The S3 relay-back rule will be CONTENT-triggered (a
  `text_contains`/`mention` matcher) with a `{:role, ...}` receiver — it carries
  no instance URI, so this Definition survives a live-session snapshot back into a
  Definition (round-trip) without tripping `reject_participant_instance_uris`.
  """

  @definition_name "kanban-team"

  @doc """
  The `kanban-team` Definition body (config-as-data). The single source S3
  extends with `routing_rules` + `legends`.
  """
  @spec definition_body() :: map()
  def definition_body do
    %{
      name: @definition_name,
      title: "Kanban Team",
      description: "pm 协调 + dev-together 开发 + 看板数据，内容触发 relay-back。",
      uses: ["kanban"],
      bases: [Ezagent.ActionSet.Session],
      shape: [],
      views: [],
      roles: [
        %{
          role_name: "pm-coordinator",
          fill: :agent,
          recipe: "pm-coordinator",
          flavor: "cc-headless"
        },
        %{role_name: "dev-together", fill: :agent, recipe: "dev-together", flavor: "cc-headless"},
        %{role_name: "kanban-manager", fill: :agent, recipe: "kanban-manager", flavor: "native"}
      ],
      routing_rules: [],
      legends: %{},
      prompt_templates: %{},
      adapters: [],
      visibility_policy: %{publish_policy: :auto, web_anon_access: false, scope: :private},
      owner_policy: %{type: :installer}
    }
  end

  @doc """
  Code-seed the `kanban-team` Definition into `ws` (default `workspace://system`),
  idempotent via `DefinitionRegistry.seed_definition_if_absent/2` (mirrors hello's
  code-seed; does NOT clobber an existing override). The `actor_uri` is the system
  admin, derived STRUCTURALLY (`Ezagent.URI.user(:system, :admin)`) so this prod
  lib does not depend on the identity domain.
  """
  @spec seed_definition(URI.t()) :: {:ok, :seeded | :exists} | {:error, term()}
  def seed_definition(ws \\ Ezagent.URI.workspace(:system)) do
    Ezagent.Socialware.DefinitionRegistry.seed_definition_if_absent(
      definition_body(),
      workspace_uri: ws,
      actor_uri: Ezagent.URI.user(:system, :admin)
    )
  end
end
