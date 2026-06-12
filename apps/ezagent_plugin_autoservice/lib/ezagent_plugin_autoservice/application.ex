defmodule EzagentPluginAutoservice.Application do
  @moduledoc """
  Autoservice plugin OTP application — the `Ezagent.Plugin` contract
  module for the customer-service vertical.

  ## What this plugin is

  A thin assembly layer on top of existing ezagent primitives that turns
  the platform into a multi-tenant customer-service product:

  - a tenant = a Workspace (e.g. `workspace://cinnox`)
  - per-customer Session with socialware Turn semantics
  - **operator** — sees the workspace's customer sessions and can join
    any of them to talk to the customer directly

  ## Declarations

  - `behaviors/0` — `{CsOrchestrator Kind, action, Behavior}` triples.
  - `agent_flavors/0` — flavor `"cs_orchestrator"` → `CsOrchestrator` Kind.
  - `children/0` — `EzagentPluginAutoservice.InstanceSupervisor` (DynamicSupervisor).
  - `after_boot/0` — re-registers the flavor tag for every persisted
    orchestrator so they survive a node restart (see below).

  ## AgentFlavorAttributes durability — `after_boot/0` re-registration

  `AgentFlavorAttributes` is a non-durable ETS cache (its own moduledoc:
  "its persisted sandbox slice remains the durable restart source; this
  table is [a cache]"). The flavor→Kind map (`agent_flavors/0`) IS durable
  (re-published every boot), but the *uri→flavor* tag is only put into ETS
  at provision time — in the provisioning BEAM. After a server restart the
  cache is empty, so the cold-load resolver's flavor step
  (`AgentModuleResolver.lookup_via_stored_flavor` → `UriQuery.resolve(:flavor)`)
  returns `:none` and a dormant orchestrator dispatch fails with
  `:no_such_actor` — the customer message never reaches the orchestrator,
  so no turn opens and no reply is produced. (cc/curl agents are immune:
  their `kind_type` — `agent`/`curl_agent` — is resolved by the resolver's
  step 1, which reads the durable snapshot column.)

  `after_boot/0` (Phase-3 of `Ezagent.Plugin.boot/1`, after this plugin's
  `agent_flavors/0` is published) enumerates every persisted snapshot whose
  durable `kind_type` is `"cs_orchestrator"` and re-`put`s its flavor tag,
  rehydrating the cache so dormant orchestrators cold-load on the next
  customer message. It best-effort warm-spawns each so the first message
  doesn't pay cold-load latency. Enumeration uses the durable snapshot index
  (`Ezagent.Ecto.KindSnapshot.list_all/0` filtered by `kind_type` — the same
  index the resolver reads; precedent: `Orchestrator.McpServer`,
  `Orchestrator.Tools.Templates`), NOT the §11-barred `SnapshotStore`.

  Framework gap flagged to Allen: generic rehydration of the
  `AgentFlavorAttributes` cache from the durable slice at boot arguably
  belongs in core (every non-core-kind agent-flavor plugin hits this), not
  in each plugin's `after_boot/0`.
  """

  use Application
  use Ezagent.Plugin

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract -----------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "autoservice",
      name: "Autoservice",
      description:
        "Multi-tenant customer-service vertical: per-customer sessions with " <>
          "socialware turn semantics, operator console, and workspace-scoped admin.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.CsOrchestrator, :receive, Ezagent.Behavior.CsOrchestrator},
      # Agent replies (fast/slow) reach the orchestrator via the bridge as
      # chat.send — see CsOrchestrator's :send action (delegates to :receive).
      {Ezagent.Entity.CsOrchestrator, :send, Ezagent.Behavior.CsOrchestrator},
      {Ezagent.Entity.CsOrchestrator, :operator_claim, Ezagent.Behavior.CsOrchestrator},
      {Ezagent.Entity.CsOrchestrator, :operator_settle, Ezagent.Behavior.CsOrchestrator}
    ]
  end

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "cs_orchestrator",
        kind: Ezagent.Entity.CsOrchestrator,
        # No template class in Phase C3 — provision task (C4) owns creation.
        template_class: nil
      }
    ]
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor,
       name: EzagentPluginAutoservice.InstanceSupervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  Phase-3 post-register hook: rehydrate the non-durable
  `AgentFlavorAttributes` cache for every persisted orchestrator so they
  survive a node restart (see the moduledoc "durability" section).

  Runs after this plugin's `agent_flavors/0` is published, so the
  flavor→Kind map is in place when a re-tagged orchestrator cold-loads.
  Non-fatal throughout — a failure here must not abort plugin boot.
  """
  @impl Ezagent.Plugin
  def after_boot do
    orchestrators =
      try do
        Ezagent.Ecto.KindSnapshot.list_all()
        |> Enum.filter(&(&1.kind_type == "cs_orchestrator"))
      rescue
        # DB not ready / unavailable at boot — nothing to rehydrate yet.
        # Orchestrators provisioned after boot get tagged at provision time.
        _ -> []
      end

    Enum.each(orchestrators, fn %{uri: uri_str} ->
      case Ezagent.URI.parse(uri_str) do
        {:ok, uri} ->
          :ok = Ezagent.AgentFlavorAttributes.put(uri, "cs_orchestrator")
          # Best-effort warm spawn (so the first customer message skips
          # cold-load latency). Non-fatal: if it fails the orchestrator
          # still cold-loads on the next dispatch now that its flavor tag
          # is back in the cache.
          _ = Ezagent.SpawnRegistry.spawn(uri)
          :ok

        _ ->
          :ok
      end
    end)

    :ok
  end
end
