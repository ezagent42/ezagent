defmodule EzagentPluginKanban.Demo do
  @moduledoc """
  The **kanban demo socialware** — the one source of truth for the kanban
  manifest and its boot-time publish (the hello golden template, task #162 play;
  Allen's 2026-07-06 kanban-boot-publish handoff).

  A fresh stack ships a discoverable, installable **kanban** socialware, seeded
  by DOGFOODING the real publish path (`Ezagent.Socialware.ConfigGovernance
  .Socialware`: `open_cr → stage_definition → publish_cr`), NOT a hard-coded
  direct ConfigStore write. Every boot exercises the real governance flow, so a
  broken publish path fails LOUD at boot. This module supersedes the retired
  `EzagentPluginKanban.KanbanTeam` imperative code-seed
  (`DefinitionRegistry.seed_definition_if_absent`) — publish is now the ONLY
  boot seeding path (hello parity: hello also only publishes).

  ## One definition of truth

  `manifest_attrs/1` returns the config-authored manifest shape (string
  name-refs, `ManifestResolver.resolve/1`-ready). Tests source their fixture
  manifests from here with per-run unique names / a bare-spawn stub flavor
  (parallel-test isolation, no cc SDK sidecar); the boot path calls it with the
  stable demo defaults (`name: "kanban"`, both role slots on `cc-headless`).
  Same source → the fixtures and the boot demo can never drift.

  ## The kanban team shape (three data diffs vs hello, per the handoff)

    * `roles` — exactly TWO agent role-slots, `kanban-assistant` (cc-headless
      pm/coordinator) + `dev-together` (cc-headless developer). **NOT** the
      handoff's example `kanban-manager × native` slot: the board actor is
      `passive: true` and the RF-6 passive-join gate rejects it at materialize
      (`{:passive_actor_cannot_join, _}`, `Ezagent.ActionSet.Session` join
      guard; locked by `role_native_create_test`). The board stays a
      WORKSPACE-LEVEL data actor addressed by `entity://<ws>/agent/<id>` and
      driven via `kanban.<action>` dispatch — the S2 modeling fix. Divergence
      reported to Allen in the return doc.
    * `routing_rules` — ONLY the #1190 content-triggered relay-back rule
      (`text_contains "__done__"` → the `kanban-assistant` role). Never hello's
      `always → chat` rule (the handoff explicitly forbids copying it).
    * `visibility_policy` — `scope: public` + `publish_policy: supervised` like
      hello, but `web_anon_access: false` (a kanban board is not an anonymous
      public page).

  ## Where it publishes

  Into `workspace://system` as a `scope: :public` definition — cross-workspace
  discoverable via `DefinitionRegistry.list/1` from EVERY workspace; users
  self-install through the normal discover→install flow (the "新建会话 →
  Socialware 下拉" entry).

  ## Authority

  `caller` = the bootstrap admin URI (`user://system/admin`), `caps` = the
  socialware `manage` cap for `kanban` in the system workspace +
  `Ezagent.Capability.admin_genesis_cap/0` (the admin gate `publish_cr/2`
  requires for a `:public` scope).

  ## Idempotency

  `publish/0` routes through the shared idempotency RULE
  (`ConfigGovernance.Socialware.publish_or_upgrade/2`, P0 §5): first publish →
  `{:ok, :published}`; an unchanged redeploy no-ops to `{:ok, :exists}` WITHOUT
  opening a CR; an EDITED manifest re-promotes to `{:ok, :upgraded}`. Combined
  with the fail-loud boot guard at the call site, a partial publish crashes the
  boot rather than silently accumulating CRs.
  """

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, ManifestResolver}
  alias Ezagent.Socialware.ConfigGovernance.Socialware, as: Governance

  @name "kanban"
  @pm_role "kanban-assistant"
  @dev_role "dev-together"
  @default_flavor "cc-headless"

  # The dev-together completion marker (spec §4.2). The SINGLE contract point
  # between the routing transport and the skill protocol — this literal MUST be
  # byte-identical to the `__done__` marker documented in
  # `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md` +
  # `.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md`
  # (locked by `.claude/skills/kanban-assistant/scripts/relay-signal-check.sh`).
  @relay_done_marker "__done__"
  @relay_rule_set "relay-back"

  @doc "The stable demo socialware name (`\"kanban\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The owner workspace URI string the demo publishes into (`workspace://system`)."
  @spec owner_workspace_uri() :: String.t()
  def owner_workspace_uri, do: DefinitionRegistry.system_workspace_uri()

  @doc "The dev-together completion marker wired into the relay-back matcher (spec §4.2 contract point)."
  @spec relay_done_marker() :: String.t()
  def relay_done_marker, do: @relay_done_marker

  @doc """
  The kanban demo manifest attributes (config-authored, string name-refs).

  Options (all default to the stable demo values):
    * `:name` — the socialware/definition name (default `"kanban"`; tests pass
      per-run unique names for parallel-test isolation)
    * `:flavor` — the flavor BOTH agent role-slots materialize on (default
      `"cc-headless"`; integration tests swap in a bare-spawn stub so no SDK
      sidecar starts — role names / recipes / routing stay the shipped ones)

  The returned map is `ManifestResolver.resolve/1`-ready (name refs, not
  modules): `views: ["kanban_render"]` resolves through the registered
  `BoardView` to `Ezagent.ActionSet.KanbanRender`; `uses: ["kanban"]` requires
  this plugin registered — both true once `Application.start/2` ran.
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    flavor = Keyword.get(opts, :flavor, @default_flavor)

    %{
      "name" => name,
      "version" => "0.1.0",
      "title" => "Kanban 看板团队",
      "description" =>
        "看板团队 socialware：kanban-assistant 协调 + dev-together 开发 + " <>
          "workspace 看板数据，__done__ 内容触发 relay-back。",
      "uses" => ["kanban"],
      "bases" => ["Elixir.Ezagent.ActionSet.Session"],
      "shape" => [],
      "views" => ["kanban_render"],
      # Exactly TWO agent role-slots — the session participants (S2 modeling
      # fix). The passive `kanban-manager` board actor is NOT a slot: RF-6
      # rejects passive `session.join` at materialize; the pm reaches the board
      # by URI dispatch with its kanban action caps.
      "roles" => [
        %{"role_name" => @pm_role, "fill" => "agent", "recipe" => @pm_role, "flavor" => flavor},
        %{"role_name" => @dev_role, "fill" => "agent", "recipe" => @dev_role, "flavor" => flavor}
      ],
      # ONLY the #1190 relay-back rule — content-triggered (no sender-lock),
      # zero instance URI, round-trip safe under role-slot #1180. NEVER hello's
      # `always → chat` rule (handoff red line).
      "routing_rules" => [
        %{
          # #1212 from_role 落地后的硬锁加固（#1201 ⑥ 预案）：内容标记（软锁）
          # AND 发件人必须是 dev-together 角色成员——其他成员发同标记不再误触发。
          "matcher" => %{
            "type" => "and",
            "items" => [
              %{"type" => "text_contains", "arg" => @relay_done_marker},
              %{"type" => "from_role", "arg" => @dev_role}
            ]
          },
          "receivers" => [@pm_role],
          "rule_set" => @relay_rule_set,
          "position" => 0
        }
      ],
      "prompt_templates" => %{},
      "legends" => %{
        "kanban" => %{
          "member_set" => [@pm_role, @dev_role],
          "bound_rule_set" => @relay_rule_set,
          "fold" => false
        }
      },
      "visibility_policy" => %{
        "scope" => "public",
        "publish_policy" => "supervised",
        "web_anon_access" => false
      }
    }
  end

  @doc """
  Publish the kanban demo as a PUBLIC socialware in `workspace://system` via the
  real governance flow, through the shared idempotency RULE (P0 §5): a first
  publish is `:published`, an unchanged redeploy no-ops to `:exists` (no CR
  opened), and an EDITED manifest re-promotes to `:upgraded`.
  """
  @spec publish() :: {:ok, :published | :upgraded | :exists} | {:error, term()}
  def publish do
    ws = Ezagent.URI.workspace(:system)
    admin = Ezagent.URI.user(:system, :admin)
    ctx = admin_ctx(admin, ws)

    with {:ok, %Definition{} = definition} <- ManifestResolver.resolve(manifest_attrs()) do
      Governance.publish_or_upgrade(definition, ctx)
    end
  end

  @doc """
  Whether the kanban demo is already present as a PUBLIC definition (the
  idempotency predicate).
  """
  @spec published?() :: boolean()
  def published?, do: already_public?(Ezagent.URI.workspace(:system))

  defp admin_ctx(admin, ws) do
    %{
      caller: admin,
      workspace_uri: ws,
      caps:
        MapSet.new([
          Governance.manage_cap(@name, ws, admin),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end

  defp already_public?(ws) do
    case DefinitionRegistry.lookup(ws, @name) do
      {:ok, %Definition{visibility_policy: %{scope: :public}}, _object} -> true
      _ -> false
    end
  end
end
