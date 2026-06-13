defmodule Ezagent.Behavior.OrchestratorTools do
  @moduledoc """
  Session-side dispatch surface for the orchestrator's 7 management tools
  (decomposition spec §3.4 / O-4 — "transport → cc, operations → session").

  ## The transport/operations split (O-4)

  A live `claude` orchestrator reaches its 7 tools through an MCP transport
  that the **cc plugin** owns (`Ezagent.Orchestrator.McpChannel` /
  `McpSocket` / `McpServer`). On a `tools/call`, the cc transport DECODES
  the wire request and FORWARDS it via `Ezagent.Invocation.dispatch` to a
  named session action on THIS Behavior
  (`session://…?action=orchestrate.<tool>`), carrying ONLY the
  orchestrator's caller URI:

      ctx.caller = orchestrator_uri
      ctx.caps   = MapSet.new()     # NO ambient / plugin-minted authority

  The cc transport supplies **no capability authority** — the 4 delegated
  caps NEVER cross the plugin boundary. This Behavior reconstructs them
  SESSION-SIDE (all session-domain data) at the dispatch chokepoint
  (Invariant #19 normalize-at-chokepoint; Invariant #5 narrow-only), then
  runs the underlying op under those reconstructed caps. This kills the
  prior PR-8 violation where the cc plugin reconstructed + carried the
  delegated caps itself (plugin-minted authority).

  ## Two-layer authorization (preserves today's contract)

  1. **Structural entry gate (this Behavior).** Each `orchestrate.<tool>`
     action is `cap_exempt` at the generic CapBAC chokepoint and is instead
     authorized by a fail-closed in-handler check: `ctx.caller` MUST equal
     THIS session's stored orchestrator URI
     (`template_working_copy.orchestrator_uri`, a durable session-domain
     field). An arbitrary caller — or another session's orchestrator —
     is DENIED `{:error, :unauthorized}`. This is the session-side analogue
     of the cc `McpChannel.join/3` "topic URI == token-authenticated agent
     URI" gate, now enforced where the session data lives.

  2. **Per-tool delegated-cap gate (unchanged).** After the structural
     gate, this Behavior reconstructs the orchestrator's 4 delegated caps
     (via the SAME privileged `identity.list_caps` read the cc transport
     used to perform) and runs the op via `Ezagent.Orchestrator.ToolRunner`
     under those caps. Each underlying `Ezagent.Orchestrator.Tools.<tool>`
     op enforces its delegated cap AT EVERY DISPATCH (cap #1 within_session,
     cap #2 spawned_by, caps #3/#4 template) — a missing delegated cap
     returns `{:error, :unauthorized}`, NEVER a fallback to ambient
     `admin_caps`. The cap reconstruction is scope-bounded narrowing only
     (Invariant #5); it grants the orchestrator nothing it was not already
     delegated at Generator boot (§1.4).

  ## Why cap-exempt rather than a per-action cap

  The orchestrator does NOT hold a cap named `orchestrate.<tool>`; its
  authority over its own session is the structural fact that it IS the
  session's orchestrator (recorded durably at create). Gating the entry on
  a structural identity check — rather than a held cap — matches the
  existing model exactly: today the WIRE gate is "the bridge can only join
  the topic for the orchestrator whose token it holds", and the OP gate is
  "each tool runs under the orchestrator's delegated caps". This Behavior
  reproduces BOTH session-side. The structural check is STRICTER than a
  cap-axis match (it pins the exact orchestrator instance), so cap-exempt
  here is a tightening, not a bypass.

  ## Registration

  Registered against `Ezagent.Entity.Session` in
  `EzagentDomainInstanceMessage.Application.start/2`. Lives in
  `ezagent_domain_instance_message` (domain.session) because the ops it
  forwards into MUTATE session/routing state.

  ## Naming (§11 NP-1/NP-2/NP-3)

  `Ezagent.Behavior.OrchestratorTools` — a domain module (NP-2 permits an
  `Orchestrator`-named domain module outside `apps/ezagent_core`). The name
  matches its action set (the orchestrator tools); width OK (NP-3).
  """

  use Ezagent.Lifecycle, state_slice: :orchestrator_tools

  require Logger

  alias Ezagent.Orchestrator.ToolRunner

  # The structural authz + the delegated-cap reconstruction read the live
  # session's `:chat` (`:session`) slice — orchestrator URI, owner URI,
  # parent/session template URI all live there.
  reads_siblings([:session])

  # Each `orchestrate.<tool>` action. `caps:` defaults to `[<action>]` (the
  # macro default) — moot here, the actions are `cap_exempt` (the structural
  # in-handler check is the entry authority). `modes: [:call]` — the
  # transport forwards synchronously and consumes the tool result.
  @desc "Run an orchestrator management tool on this session. Cap-exempt at the generic chokepoint; authorized by a fail-closed in-handler check that the caller IS this session's orchestrator, then run under the orchestrator's reconstructed delegated caps (O-4)."

  action(:add_managed_member, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:update_member_template, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:remove_member, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:define_rule_set_rule, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:define_prompt_template, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:define_legend, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:update_template, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:save_template_as, args: %{}, returns: %{}, modes: [:call], description: @desc)
  action(:list_templates, args: %{}, returns: %{}, modes: [:call], description: @desc)

  # Every action is `cap_exempt` at the generic CapBAC chokepoint — the
  # fail-closed structural caller-is-our-orchestrator check in `run/3` is
  # the SOLE entry authority (the delegated caps gate the underlying ops).
  # MUST equal `actions/0` (the parity invariant asserts
  # `required_caps keys ∪ cap_exempt == actions`).
  @impl Ezagent.Behavior
  def cap_exempt_actions, do: ToolRunner.tool_names()

  # The `action/3` macro auto-emits cap subjects from the `caps:`
  # declarations, so the caps-data-ownership invariant requires a
  # `data_owner/1`. These actions are `cap_exempt` — they NEVER gate via a
  # held cap, so there is no grantable cap-owner to formalize. `:no_owner`
  # documents "no grantable authority" (the authority is the live
  # structural check), exactly as `SocialwarePublisherRead` does.
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner

  # `create/1` — the Behavior holds NO durable state (it is a pure dispatch
  # surface). The `:orchestrator_tools` slice is empty; `activate/2` is the
  # macro no-op default (no transients).
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  # --- handlers (one per tool; all share `run/3`) ------------------------

  def handle_add_managed_member(args, ctx), do: run(:add_managed_member, args, ctx)
  def handle_update_member_template(args, ctx), do: run(:update_member_template, args, ctx)
  def handle_remove_member(args, ctx), do: run(:remove_member, args, ctx)
  def handle_define_rule_set_rule(args, ctx), do: run(:define_rule_set_rule, args, ctx)
  def handle_define_prompt_template(args, ctx), do: run(:define_prompt_template, args, ctx)
  def handle_define_legend(args, ctx), do: run(:define_legend, args, ctx)
  def handle_update_template(args, ctx), do: run(:update_template, args, ctx)
  def handle_save_template_as(args, ctx), do: run(:save_template_as, args, ctx)
  def handle_list_templates(args, ctx), do: run(:list_templates, args, ctx)

  # The dispatched-tool args arrive under `args.arguments` (the LLM's
  # JSON-decoded argument map, forwarded verbatim by the cc transport).
  # The structural authz + cap reconstruction + op run is one path.
  #
  # Returns `{:ok, result, []}` — the raw tool `{:ok, value}` / `{:error,
  # reason}` is carried as the action RESULT (the cc transport encodes it to
  # the MCP shape). Emits NO effects: the underlying `Tools.<tool>` ops
  # mutate state through their OWN dispatches (under the reconstructed
  # caps), not via this Behavior's slice.
  defp run(tool, args, ctx) do
    arguments = decode_arguments(args)

    with :ok <- authorize_caller_is_orchestrator(ctx),
         {:ok, opts} <- reconstruct_orchestrator_ctx(ctx) do
      {:ok, ToolRunner.run_tool(tool, arguments, opts), []}
    else
      {:error, reason} ->
        # Surface the raw error as the action RESULT (not a dispatch-level
        # error) so the cc transport encodes a structured MCP tool error
        # rather than a transport failure. `:unauthorized` from the
        # structural gate maps to the same MCP `unauthorized` code the
        # per-tool cap denial does.
        {:ok, {:error, reason}, []}
    end
  end

  # The LLM-supplied argument map travels as `args.arguments` (string-keyed)
  # from the cc transport's decode. A direct value-form call may pass it
  # under `:arguments` (atom) too. Default to `%{}`.
  defp decode_arguments(args) do
    cond do
      is_map(Map.get(args, "arguments")) -> Map.get(args, "arguments")
      is_map(Map.get(args, :arguments)) -> Map.get(args, :arguments)
      true -> %{}
    end
  end

  # === Structural entry gate (THE security boundary) =====================
  #
  # Authorize ONLY when `ctx.caller` is a well-formed identity-principal
  # `%URI{}` AND it equals THIS session's stored orchestrator URI. A
  # nil/malformed caller, a session with no orchestrator, or a DIFFERENT
  # orchestrator → `{:error, :unauthorized}` (fail-closed; no
  # "allow if orchestrator is nil" branch).
  defp authorize_caller_is_orchestrator(ctx) do
    with %URI{} = caller <- valid_caller(Map.get(ctx, :caller)),
         %URI{} = orchestrator_uri <- session_orchestrator_uri(ctx),
         true <- URI.to_string(caller) == URI.to_string(orchestrator_uri) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # A WELL-FORMED bare identity-principal URI (entity://<ws>/<type>/<name>).
  # Rejects nil / :any / :system / non-URI / non-entity values.
  defp valid_caller(%URI{} = uri) do
    if Ezagent.URI.bare_principal?(uri), do: uri, else: nil
  rescue
    _ -> nil
  end

  defp valid_caller(_), do: nil

  # === Session-side context reconstruction (O-4) =========================
  #
  # Reconstruct the orchestrator's full caller context from SESSION-DOMAIN
  # data — the live `:chat` sibling slice + the orchestrator's own
  # `:identity` slice. NOTHING is trusted from the wire (the cc transport
  # carried only the caller URI).
  defp reconstruct_orchestrator_ctx(ctx) do
    with %URI{} = session_uri <- Map.get(ctx, :self_uri),
         %URI{} = workspace_uri <- resolve_workspace_uri(ctx, session_uri),
         %URI{} = orchestrator_uri <- Map.get(ctx, :caller) do
      wc = working_copy(ctx)
      owner_uri = owner_uri(ctx) || orchestrator_uri
      parent_template_uri = Map.get(wc, :session_template_uri)

      opts = [
        caller: orchestrator_uri,
        caps: load_orchestrator_caps(orchestrator_uri),
        session_uri: session_uri,
        workspace_uri: workspace_uri,
        owner: owner_uri,
        parent_template_uri: parent_template_uri
      ]

      {:ok, opts}
    else
      _ -> {:error, :orchestrator_context_unavailable}
    end
  end

  # The session's stored orchestrator URI — the durable
  # `template_working_copy.orchestrator_uri` field (set once at create,
  # read through the working copy, NEVER re-derived from URI shape).
  defp session_orchestrator_uri(ctx) do
    case Map.get(working_copy(ctx), :orchestrator_uri) do
      %URI{} = uri -> uri
      _ -> nil
    end
  end

  defp working_copy(ctx) do
    Ezagent.Behavior.Session.template_working_copy(chat_slice(ctx))
  end

  defp owner_uri(ctx) do
    case Map.get(chat_slice(ctx), :owner_uri) do
      %URI{} = uri -> uri
      _ -> nil
    end
  end

  defp chat_slice(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:session, %{})
    |> case do
      %{} = slice -> slice
      _ -> %{}
    end
  end

  defp resolve_workspace_uri(ctx, %URI{} = session_uri) do
    case Map.get(ctx, :workspace_uri) do
      %URI{} = ws ->
        ws

      _ ->
        case Ezagent.Capability.workspace_of(session_uri) do
          %URI{} = ws -> ws
          _ -> nil
        end
    end
  end

  # Reconstruct the orchestrator agent's 4 delegated caps by privileged-
  # reading its OWN `:identity` slice — relocated SESSION-side so NO caps
  # cross the plugin boundary (O-4). We route through the Identity domain's
  # sanctioned `Ezagent.Identity.list_caps_for/1` helper rather than a bare
  # `Invocation.dispatch` here: a Lifecycle handler must NOT call the dispatch
  # engine directly (it emits effects / delegates) — the privileged cap-read
  # indirection is the Identity domain's concern, and `list_caps_for/1` is the
  # canonical reader (it awaits readiness, then dispatches `identity.list_caps`
  # for the agent's OWN caps). It is TRUSTED INFRASTRUCTURE reading the
  # orchestrator's OWN delegated caps; it grants nothing — the loaded caps are
  # exactly what the Generator delegated (§1.4). An orchestrator with no
  # delegated caps yields an empty set, and every underlying tool then DENIES
  # at the dispatch chokepoint (no `admin_caps` fallback).
  defp load_orchestrator_caps(%URI{} = orchestrator_uri) do
    Ezagent.Identity.list_caps_for(orchestrator_uri)
  rescue
    _ -> MapSet.new()
  end
end
