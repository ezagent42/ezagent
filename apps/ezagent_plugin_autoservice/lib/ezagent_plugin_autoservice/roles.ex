defmodule EzagentPluginAutoservice.Roles do
  @moduledoc """
  CapBAC role bundles for the AutoService CS vertical (v2 §4.2/§4.3).

  Each public function returns a list of `%Ezagent.Capability{}` structs
  that can be granted to a principal via `identity.grant_cap` dispatch.

  ## Role summary

  - `:master_admin` — cross-workspace admin (workspace/content/user, all `:any` scope)
  - `:tenant_admin`  — ws-scoped workspace manage + content write + user create
  - `:operator`      — session join + turn claim/settle + orchestrator takeover
    (NOTE: operator bundle includes one cap beyond v2 §4.2's 3 caps:
     `{kind: :cs_orchestrator, behavior: CsOrchestrator, action: :operator_claim/:operator_settle, ...}`
     These are required so the operator can dispatch `operator_claim`/`operator_settle`
     to the CS Orchestrator Kind without holding bootstrap caps. This addition is
     documented as a SPEC extension — see NEEDS_DECISION note in the report.)
  - `:customer`      — session send + session receive, ws-scoped

  ## Module-name verification (grep results)

  - `Ezagent.Behavior.Workspace`         — confirmed exists in ezagent_domain_workspace
  - `Ezagent.Behavior.WorkspaceUserAdmin` — confirmed exists in ezagent_domain_identity
  - `Ezagent.Behavior.Turn`              — confirmed exists in ezagent_domain_socialware
  - `Ezagent.Behavior.CsOrchestrator`    — this plugin (operator takeover Behavior)

  ## Construction pattern

  Caps are constructed as `%Ezagent.Capability{}` structs directly (not via
  atom-keyed maps) so `normalize!/2` is a pass-through at the grant chokepoint.
  `granted_by` is set to `Ezagent.Entity.User.admin_uri()` — the same granter
  the Assembly's grant_ctx uses (caller = admin_uri). `granted_at: DateTime.utc_now()`
  is set at bundle construction time.
  """

  alias Ezagent.Capability
  alias Ezagent.Entity.User

  @type role :: :master_admin | :tenant_admin | :operator | :customer

  @doc """
  Return the capability bundle for `role` scoped to workspace `ws`.

  For `:master_admin`, `ws` is ignored (all caps carry `workspace_uri: :any`).
  """
  @spec bundle(role(), URI.t()) :: [Capability.t()]
  def bundle(role, ws)

  # ---------------------------------------------------------------------------
  # :master_admin — v2 §4.2: workspace/content/user, all :any scope
  # ---------------------------------------------------------------------------

  def bundle(:master_admin, _ws) do
    gb = User.admin_uri()
    now = DateTime.utc_now()

    [
      # workspace: manage any instance in any workspace
      %Capability{
        kind: :workspace,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: gb,
        granted_at: now
      },
      # content: write any instance in any workspace
      %Capability{
        kind: :content,
        behavior: :any,
        action: :write,
        instance: :any,
        workspace_uri: :any,
        granted_by: gb,
        granted_at: now
      },
      # user: create any instance in any workspace
      %Capability{
        kind: :user,
        behavior: :any,
        action: :create,
        instance: :any,
        workspace_uri: :any,
        granted_by: gb,
        granted_at: now
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # :tenant_admin — v2 §4.2: ws-scoped manage + content:write + user:create
  # ---------------------------------------------------------------------------

  def bundle(:tenant_admin, %URI{} = ws) do
    gb = User.admin_uri()
    now = DateTime.utc_now()

    [
      # workspace: manage the ws instance itself
      %Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        instance: ws,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # content: write ws-scoped content instances
      %Capability{
        kind: :content,
        behavior: :any,
        action: :write,
        instance: ws,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # user: create users in this workspace
      %Capability{
        kind: :user,
        behavior: Ezagent.Behavior.WorkspaceUserAdmin,
        action: :create_user,
        instance: ws,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # :operator — v2 §4.2: session:join + turn:claim + turn:settle (ws-scoped)
  # Plus orchestrator dispatch caps (SPEC extension — see moduledoc).
  # ---------------------------------------------------------------------------

  def bundle(:operator, %URI{} = ws) do
    gb = User.admin_uri()
    now = DateTime.utc_now()

    [
      # session: join any session in this workspace
      %Capability{
        kind: :session,
        behavior: :any,
        action: :join,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # turn: claim any turn in this workspace
      %Capability{
        kind: :turn,
        behavior: Ezagent.Behavior.Turn,
        action: :claim,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # turn: settle any turn in this workspace
      %Capability{
        kind: :turn,
        behavior: Ezagent.Behavior.Turn,
        action: :settle,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # SPEC extension (beyond §4.2): operator_claim on cs_orchestrator
      # Required so operator can dispatch operator_claim to the CsOrchestrator Kind.
      # The cap_for_action check for cs_orchestrator.operator_claim resolves to
      # {kind: :cs_orchestrator, behavior: Ezagent.Behavior.CsOrchestrator,
      #  action: :operator_claim, instance: <orch_uri>, workspace_uri: <ws>}.
      # instance: :any covers any orchestrator in this workspace.
      # NEEDS_DECISION: this cap is not in v2 §4.2; it's the minimal addition
      # to support orchestrator takeover dispatch without bootstrap caps.
      %Capability{
        kind: :cs_orchestrator,
        behavior: Ezagent.Behavior.CsOrchestrator,
        action: :operator_claim,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # SPEC extension: operator_settle on cs_orchestrator (same rationale)
      %Capability{
        kind: :cs_orchestrator,
        behavior: Ezagent.Behavior.CsOrchestrator,
        action: :operator_settle,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # :customer — v2 §4.2: session:send + session:receive, ws-scoped
  # ---------------------------------------------------------------------------

  def bundle(:customer, %URI{} = ws) do
    gb = User.admin_uri()
    now = DateTime.utc_now()

    [
      # session: send messages in any session in this workspace
      %Capability{
        kind: :session,
        behavior: :any,
        action: :send,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      },
      # session: receive messages from any session in this workspace
      %Capability{
        kind: :session,
        behavior: :any,
        action: :receive,
        instance: :any,
        workspace_uri: ws,
        granted_by: gb,
        granted_at: now
      }
    ]
  end
end
