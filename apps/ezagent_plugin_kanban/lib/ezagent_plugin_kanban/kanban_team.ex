defmodule EzagentPluginKanban.KanbanTeam do
  @moduledoc """
  The `socialware:kanban-team` Definition (S2) — a prewired team of a
  `pm-coordinator` (cc-headless coordinator), a `dev-together` (cc-headless
  developer running the copied dev-together skill), and a `kanban-manager`
  (native passive board actor). Published via code-seed (imperative
  `seed_definition_if_absent`, the hello `EzagentPluginHello.App` play), NOT a
  plugin package manifest (`core/manifest.ex` rejects a `:socialware` seed_ref by
  design). S3 adds the content-triggered relay-back `routing_rules` to this body.

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
  (`:fixed` is rejected).

  ## S3 relay-back — CONTENT-triggered, zero URI (round-trip safe)

  The relay-back rule (dev-together → pm-coordinator hand-off signal) is a single
  CONTENT-triggered routing rule: matcher `{:text_contains, "__done__"}` (the
  dev's completion marker) with receiver `{:role, "pm-coordinator"}` (a declared
  role NAME, expanded to the pm member's per-session URI at delivery via the
  `:member_by_role` resolver). It carries NO participant instance URI and NO
  `{:from}` sender-lock — so even after materialize spawns the pm/dev members at
  random UUID URIs, the live rule (and a snapshot of it back into a Definition)
  stays clean and survives `reject_participant_instance_uris`. That is the
  round-trip advantage over a sender-lock rule (which would embed the dev's
  spawned UUID and be rejected on read-back). The behavioral contract ("dev sends
  `__done__` after `return`, pm reviews then advances") is a soft protocol living
  in the two roles' skills, not encoded in routing (spec §0.1/§4.4).
  """

  @definition_name "kanban-team"

  # The dev-together completion marker (spec §4.2). The SINGLE contract point
  # between the routing transport and the skill protocol — this literal MUST be
  # byte-identical to the `__done__` marker documented in
  # `.claude/skills/pm-coordinator/references/kanban-team-collaboration.md` +
  # `.claude/skills/dev-together/references/kanban-team-relay.md`.
  @relay_done_marker "__done__"
  @relay_rule_set "relay-back"

  @doc "The dev-together completion marker wired into the relay-back matcher (spec §4.2 contract point)."
  @spec relay_done_marker() :: String.t()
  def relay_done_marker, do: @relay_done_marker

  @doc """
  The `kanban-team` Definition body (config-as-data). Includes the S3
  content-triggered relay-back `routing_rules` (zero instance URI, round-trip
  safe).
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
      # Relay-back: the dev-together `__done__` completion signal routes to the
      # pm-coordinator ROLE. Content-triggered (no sender-lock), zero URI — even
      # after materialize spawns pm/dev at random UUID URIs, the live rule (and a
      # snapshot of it back into a Definition) stays clean, so it survives
      # `reject_participant_instance_uris` (round-trip safe, spec §4.4).
      routing_rules: [
        %{
          "matcher" => %{"type" => "text_contains", "arg" => @relay_done_marker},
          "receivers" => ["pm-coordinator"],
          "rule_set" => @relay_rule_set,
          "position" => 0
        }
      ],
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
