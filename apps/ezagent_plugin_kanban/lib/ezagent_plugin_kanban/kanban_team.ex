defmodule EzagentPluginKanban.KanbanTeam do
  @moduledoc """
  The `socialware:kanban-team` Definition (S2) — a prewired team of TWO session
  participants: a `kanban-assistant` (cc-headless coordinator) and a `dev-together`
  (cc-headless developer running the copied dev-together skill). Published via
  code-seed (imperative `seed_definition_if_absent`, the hello
  `EzagentPluginHello.App` play), NOT a plugin package manifest
  (`core/manifest.ex` rejects a `:socialware` seed_ref by design). S3 adds the
  content-triggered relay-back `routing_rules` to this body.

  ## Board is not a member (the S2 modeling fix)

  The kanban board (`kanban-manager` recipe × `native` flavor) is `passive`
  (`Application.kanban_manager_recipe/0` `passive: true`) — a WORKSPACE-LEVEL
  board DATA actor addressed by `entity://<ws>/agent/<id>`, dispatched to with
  `kanban.<action>`. It is NOT a session participant. An earlier draft declared it
  as a third agent role-slot, but that is a modeling bug: materialize would call
  `session.join` on the passive board and hit the RF-6 passive-join gate
  (`{:passive_actor_cannot_join, _}`, `session.ex:723`; locked by
  `role_native_create_test`). So `roles` holds ONLY pm + dev.

  How the board is supplied + reached (self-contained, no new machinery):

    * **Supply** — the board is created by the world/owner via the existing
      `/plugins/kanban` create path (`Ezagent.World.KanbanActions.create_kanban`
      → `Ezagent.Workspace.create_agent`, flavor `native` × role `kanban-manager`,
      `kanban_actions.ex:296`). Board creation is an operator/world-UI function
      (needs a workspace cap + a caller_ctx), NOT an agent-dispatchable action, so
      the pm does not self-build it.
    * **Access** — the pm drives the board with its existing `kanban_action_caps`
      (`Application.kanban_assistant_recipe/0` `requested_caps`): it dispatches
      `kanban.<action>` to the board's `entity://<ws>/agent/<id>` URI. No new cap.

  ## Zero instance URIs (role-slot #1180, enforced) + round-trip safety

  Participants are declared via the `roles` field as agent role-slots
  (`%{role_name, fill: :agent, recipe, flavor}` — all strings, `recipe` is a
  `RecipeRegistry` NAME resolved at materialize, never a URI). The two recipe
  names are exactly the S1 `kanban-assistant` / `dev-together` recipes the kanban
  plugin declares in `EzagentPluginKanban.Application.roles/0` (which also
  declares the `kanban-manager` board recipe — the workspace board actor, not a
  member). The retired `agents`/`members` fields are rejected fail-loud by
  `Definition.new/1` (`definition.ex` `reject_retired_declaration_fields`), and
  any participant instance URI in `roles`/`routing_rules` is rejected too
  (`reject_participant_instance_uris`). `owner_policy` is `%{type: :installer}`
  (`:fixed` is rejected).

  ## S3 relay-back — CONTENT-triggered, zero URI (round-trip safe)

  The relay-back rule (dev-together → kanban-assistant hand-off signal) is a single
  CONTENT-triggered routing rule: matcher `{:text_contains, "__done__"}` (the
  dev's completion marker) with receiver `{:role, "kanban-assistant"}` (a declared
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
  # `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md` +
  # `.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md`.
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
      # Exactly TWO agent role-slots — the session participants. Both cc-headless
      # (active real-brain), so both pass the RF-6 join gate and really
      # `session.join` at materialize. The board (`kanban-manager`) is NOT here —
      # it is a workspace-level PASSIVE URI-dispatch actor, not a session member
      # (see moduledoc §Board is not a member).
      roles: [
        %{
          role_name: "kanban-assistant",
          fill: :agent,
          recipe: "kanban-assistant",
          flavor: "cc-headless"
        },
        %{role_name: "dev-together", fill: :agent, recipe: "dev-together", flavor: "cc-headless"}
      ],
      # Relay-back: the dev-together `__done__` completion signal routes to the
      # kanban-assistant ROLE. Content-triggered (no sender-lock), zero URI — even
      # after materialize spawns pm/dev at random UUID URIs, the live rule (and a
      # snapshot of it back into a Definition) stays clean, so it survives
      # `reject_participant_instance_uris` (round-trip safe, spec §4.4).
      routing_rules: [
        %{
          "matcher" => %{"type" => "text_contains", "arg" => @relay_done_marker},
          "receivers" => ["kanban-assistant"],
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
