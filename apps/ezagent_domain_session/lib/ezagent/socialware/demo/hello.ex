defmodule Ezagent.Socialware.Demo.Hello do
  @moduledoc """
  The **hello demo socialware** — the one source of truth for the hello manifest
  and its boot-time publish.

  Task #162 (Allen 2026-07-04). A fresh stack ships a discoverable, installable
  **hello** demo socialware, but seeded by DOGFOODING the real publish path
  (`Ezagent.Socialware.ConfigGovernance.Socialware`: `open_cr → stage_definition
  → publish_cr`), NOT a hard-coded direct ConfigStore write. Every boot exercises
  the real governance flow, so a broken publish path fails LOUD at boot.

  ## One definition of truth

  `manifest_attrs/1` returns the config-authored manifest shape (the same shape
  that previously lived only as the `hello_manifest_attrs` test fixture in
  `EzagentWeb.WorldConversationTest`). The acceptance test now sources its
  manifest from here with unique per-run names (parallel-test isolation); the
  boot path calls it with the stable demo defaults (`name: "hello"`, `recipe:
  "np"`, `role: "hello-helper"`). Same source → the fixture and the boot demo can
  never drift.

  ## Where it publishes

  Into `workspace://system` (where the built-in `chat`/`socialware` definitions
  live) as a `scope: :public` definition. Public scope makes it cross-workspace
  discoverable via `DefinitionRegistry.list/1` from EVERY workspace — no
  pre-install into any workspace; users self-install through the normal
  discover→install flow.

  ## Authority

  Mirrors the acceptance test's publish ctx: `caller` = the bootstrap admin URI
  (`user://system/admin`), `caps` = the socialware `manage` cap for `hello` in
  the system workspace + `Ezagent.Capability.admin_genesis_cap/0` (the admin gate
  `publish_cr/2` requires for a `:public` scope).

  ## Idempotency

  `publish/0` routes through the shared idempotency RULE
  (`ConfigGovernance.Socialware.publish_or_upgrade/2`, P0 §5): an unchanged
  redeploy no-ops to `{:ok, :exists}` WITHOUT opening a CR, so a re-boot /
  supervisor restart never re-opens a change request or writes a duplicate; an
  EDITED manifest re-promotes to `{:ok, :upgraded}` (the old existence-check
  silently swallowed manifest edits — R-2, §5.2). Combined with the fail-loud
  boot guard at the call site, a partial publish crashes the boot rather than
  silently accumulating CRs.
  """

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, ManifestResolver}
  alias Ezagent.Socialware.ConfigGovernance.Socialware, as: Governance

  @name "hello"
  @recipe "np"
  @role "hello-helper"

  @doc "The stable demo socialware name (`\"hello\"`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The owner workspace URI string the demo publishes into (`workspace://system`)."
  @spec owner_workspace_uri() :: String.t()
  def owner_workspace_uri, do: DefinitionRegistry.system_workspace_uri()

  @doc """
  The hello demo manifest attributes (config-authored, string module-refs).

  Options (all default to the stable demo values):
    * `:name` — the socialware/definition name (default `"hello"`)
    * `:recipe_name` — the agent recipe the definition materializes (default `"np"`)
    * `:role_name` — the per-session routing role of the materialized agent
      (default `"hello-helper"`)

  The returned map is `ManifestResolver.resolve/1`-ready (name refs, not modules).
  """
  @spec manifest_attrs(keyword()) :: map()
  def manifest_attrs(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    recipe_name = Keyword.get(opts, :recipe_name, @recipe)
    role_name = Keyword.get(opts, :role_name, @role)

    %{
      "name" => name,
      "version" => "0.1.0",
      "title" => "Pure-config hello",
      "description" => "Hello socialware authored as a manifest.",
      "uses" => ["hello"],
      "bases" => [
        "Elixir.Ezagent.ActionSet.Session",
        "Elixir.Ezagent.ActionSet.Publisher.SessionImpl"
      ],
      "shape" => [
        "Elixir.Ezagent.ActionSet.Turn",
        "Elixir.Ezagent.ActionSet.Surface",
        "Elixir.Ezagent.ActionSet.SupervisorApproval"
      ],
      "views" => ["hello_render"],
      "roles" => [
        %{"role_name" => role_name, "fill" => "agent", "recipe" => recipe_name, "flavor" => "py"}
      ],
      "prompt_templates" => %{"hello" => "Say hello: {body}"},
      "legends" => %{
        "hello" => %{
          "member_set" => [role_name],
          "bound_rule_set" => "default",
          "fold" => false
        }
      },
      "routing_rules" => [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => [role_name],
          "rule_set" => "default",
          "position" => 0,
          "prompt_template_ref" => "hello"
        }
      ],
      "visibility_policy" => %{
        "scope" => "public",
        "publish_policy" => "supervised",
        "web_anon_access" => true
      }
    }
  end

  @doc """
  Publish the hello demo as a PUBLIC socialware in `workspace://system` via the
  real governance flow, through the shared idempotency RULE (P0 §5): a first
  publish is `:published`, an unchanged redeploy no-ops to `:exists` (no CR
  opened), and an EDITED manifest re-promotes to `:upgraded` (killing R-2 — the
  old existence-check silently swallowed manifest edits, §5.2/§5.3).
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
  Whether the hello demo is already present as a PUBLIC definition (the
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
