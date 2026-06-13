defmodule Ezagent.Session.SessionManager do
  @moduledoc """
  Per-orchestrator MCP **executor** — a plain supervised `GenServer` in the
  session domain that runs the orchestrator's 7 management tools (Decision C,
  `docs/superpowers/specs/2026-06-13-orchestrator-sessionmanager-kind-design.md`).

  ## Why a plain GenServer (NOT a Kind)

  This is the spiritual + near-literal successor of the old per-orchestrator
  `Ezagent.Orchestrator.McpServer` GenServer: it ALREADY ran the tools in its
  own process and dispatched to the Session Kind cross-process (never
  deadlocked). Decision C relocates that executor into the session domain, with
  the wire transport split out to the cc plugin and the orchestrator's delegated
  caps reconstructed SESSION-side. A Kind corresponds to a first-class domain
  concept (each has a URI scheme); SessionManager is an EXECUTION MECHANISM, so
  it is NOT a Kind — there is no `SessionManager` URI scheme and no
  cap-exempt dispatchable action that could be a forgeable entry.

  ## Identity / addressing

  Registered in `Ezagent.Session.SessionManagerRegistry` keyed by the
  orchestrator URI string, so the cc transport can `GenServer.call` it by URI
  without naming this module (cc depends on the session domain `only: :test`).
  The cc transport reaches it via the Registry `:via` tuple built from the URI
  string — a runtime edge, NOT a compile dependency.

  ## Lifecycle

  Spawned under `Ezagent.Session.SessionManagerSupervisor` (a
  `DynamicSupervisor`) at orchestrator materialization
  (`EzagentDomainInstanceMessage.SessionCreator` step 7, alongside the existing
  MCP-context registration), terminated with the session. Near-stateless: it
  caches only the binding (`orchestrator_uri`, `session_uri`, `workspace_uri`,
  `owner_uri`, `parent_template_uri`) and RECONSTRUCTS the orchestrator's
  delegated caps on every call (they may change after spawn).

  ## Per-call flow — `handle_call({:run_tool, tool, args, bridge_token}, …)`

  0. **AUTHZ — verify the bridge token (THE unforgeable gate, §2 step 0).**
     The cc socket authenticated the orchestrator's WS connection with its
     bridge token and FORWARDS that token (its connection credential, NOT
     caps) with the call. SessionManager VERIFIES it (constant-time compare)
     against the orchestrator's known bridge token
     (`Ezagent.AgentBridge.TokenStore.token_for/1`). A mismatch / absent token
     → `{:error, :unauthorized}` (fail-loud) BEFORE anything else. Being a
     GenServer is NOT sufficient authz: the Registry key is URI-derivable and
     the pid is enumerable, so a co-resident process could `GenServer.call`
     it; only the secret token closes that. cc forwarding caps would not help
     (caps are readable, hence forgeable).
  1. **Structural check (defense-in-depth).** The bound `orchestrator_uri`
     must equal this session's stored orchestrator (the durable
     `template_working_copy.orchestrator_uri` field) — fail-closed; a
     stale/foreign binding is rejected.
  2. **Reconstruct the orchestrator's 4 delegated caps SESSION-side** — the
     privileged read of the orchestrator agent's `:identity` slice
     (`Ezagent.Identity.list_caps_for/1`), run HERE, not in cc. cc carries NO
     caps.
  3. **Run the tool** via `Ezagent.Orchestrator.Tools.<tool>` under those
     reconstructed caps. Each tool mutation `Invocation.dispatch`es to the
     **Session Kind cross-process** (SessionManager ≠ Session → no self-call),
     a complete normal dispatch where the Session chokepoint cap-checks each
     op with the reconstructed caps. THIS is where the real CapBAC gating
     happens.
  4. **Reply with the raw `{:ok, value}` / `{:error, reason}`** — cc encodes
     it into the MCP `tools/call` response.
  """

  use GenServer

  require Logger

  alias Ezagent.Orchestrator.Tools

  @registry Ezagent.Session.SessionManagerRegistry
  @supervisor Ezagent.Session.SessionManagerSupervisor

  @enforce_keys [:orchestrator_uri, :session_uri, :workspace_uri]
  defstruct [
    :orchestrator_uri,
    :session_uri,
    :workspace_uri,
    :owner_uri,
    :parent_template_uri
  ]

  @type binding :: %__MODULE__{
          orchestrator_uri: URI.t(),
          session_uri: URI.t(),
          workspace_uri: URI.t(),
          owner_uri: URI.t() | nil,
          parent_template_uri: URI.t() | nil
        }

  # --- addressing -------------------------------------------------------

  @doc "The Registry name used for `:via` addressing (exposed for cc + tests)."
  @spec registry() :: module()
  def registry, do: @registry

  @doc """
  The `:via` tuple addressing the SessionManager for `orchestrator_uri`.

  Built from the URI STRING through the shared Registry — the cc transport
  uses this (NOT an `alias` of this module) to reach the process.
  """
  @spec via(URI.t() | String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(%URI{} = orchestrator_uri), do: via(URI.to_string(orchestrator_uri))

  def via(orchestrator_uri) when is_binary(orchestrator_uri),
    do: {:via, Registry, {@registry, orchestrator_uri}}

  @doc "Look up the running SessionManager pid for `orchestrator_uri`."
  @spec whereis(URI.t() | String.t()) :: {:ok, pid()} | :error
  def whereis(%URI{} = orchestrator_uri), do: whereis(URI.to_string(orchestrator_uri))

  def whereis(orchestrator_uri) when is_binary(orchestrator_uri) do
    case Registry.lookup(@registry, orchestrator_uri) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # --- lifecycle --------------------------------------------------------

  @doc """
  Start a SessionManager bound to one orchestrator under the
  `SessionManagerSupervisor`, registered in `SessionManagerRegistry` keyed by
  the orchestrator URI string. Idempotent: if one is already running for the
  orchestrator, returns it.

  `opts` (all `%URI{}`):
  - `:orchestrator_uri` (required)
  - `:session_uri` (required)
  - `:workspace_uri` (required)
  - `:owner_uri` (optional)
  - `:parent_template_uri` (optional)
  """
  @spec ensure_started(keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts) do
    with {:ok, binding} <- build_binding(opts) do
      spec = %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [binding]},
        restart: :transient
      }

      case DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, _} = err -> err
      end
    end
  end

  @doc "Terminate the SessionManager for `orchestrator_uri` (with the session)."
  @spec stop(URI.t() | String.t()) :: :ok
  def stop(orchestrator_uri) do
    case whereis(orchestrator_uri) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
      :error -> :ok
    end

    :ok
  end

  @doc false
  @spec start_link(binding()) :: GenServer.on_start()
  def start_link(%__MODULE__{orchestrator_uri: orchestrator_uri} = binding) do
    GenServer.start_link(__MODULE__, binding, name: via(orchestrator_uri))
  end

  # --- client API -------------------------------------------------------

  @doc """
  Run an orchestrator tool against the SessionManager for `orchestrator_uri`,
  authenticated by the orchestrator's `bridge_token`.

  This is what the cc transport calls (by URI, NOT by aliasing this module —
  cc uses the bare-tuple message form via `via/1`). Returns the tool's raw
  `{:ok, value}` / `{:error, reason}`, or `{:error, :session_manager_unavailable}`
  when no SessionManager is running for the orchestrator.
  """
  @spec run_tool(URI.t() | String.t(), String.t() | atom(), map(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def run_tool(orchestrator_uri, tool, arguments, bridge_token) do
    case whereis(orchestrator_uri) do
      {:ok, pid} ->
        GenServer.call(pid, {:run_tool, tool, arguments, bridge_token})

      :error ->
        {:error, :session_manager_unavailable}
    end
  end

  # --- GenServer --------------------------------------------------------

  @impl GenServer
  def init(%__MODULE__{} = binding), do: {:ok, binding}

  @impl GenServer
  def handle_call({:run_tool, tool, arguments, bridge_token}, _from, %__MODULE__{} = binding) do
    args = if is_map(arguments), do: arguments, else: %{}
    {:reply, run(binding, tool, args, bridge_token), binding}
  end

  def handle_call(:binding, _from, %__MODULE__{} = binding), do: {:reply, binding, binding}

  # Step 0 → 1 → 2 → 3 → 4. Each gate fails CLOSED. The bridge-token check is
  # FIRST + unconditional (the unforgeable entry); only then the structural
  # check, cap reconstruction, and the cross-process tool dispatch.
  defp run(%__MODULE__{} = binding, tool, arguments, bridge_token) do
    with :ok <- verify_bridge_token(binding, bridge_token),
         :ok <- structural_check(binding),
         {:ok, tool_atom} <- normalize_tool(tool) do
      caps = load_orchestrator_caps(binding.orchestrator_uri)
      run_tool_op(tool_atom, arguments, opts(binding, caps))
    end
  end

  # === Step 0 — verify the bridge token (THE unforgeable gate) ===========
  #
  # Constant-time compare the cc-forwarded token against the orchestrator's
  # known secret from the TokenStore. A nil/non-binary token, an orchestrator
  # with no minted token, or a mismatch → `{:error, :unauthorized}` (fail-loud),
  # BEFORE any tool or cap work. The token is the orchestrator's CONNECTION
  # credential (held by the cc socket that authenticated the WS), never caps.
  defp verify_bridge_token(%__MODULE__{orchestrator_uri: orchestrator_uri}, presented)
       when is_binary(presented) do
    case Ezagent.AgentBridge.TokenStore.token_for(orchestrator_uri) do
      {:ok, known} when is_binary(known) ->
        if secure_compare(presented, known), do: :ok, else: {:error, :unauthorized}

      :error ->
        {:error, :unauthorized}
    end
  end

  defp verify_bridge_token(_binding, _presented), do: {:error, :unauthorized}

  # Constant-time byte comparison (Plug.Crypto.secure_compare/2 equivalent) —
  # avoids leaking the token via timing. Length mismatch returns false but
  # still walks the shorter string to keep the comparison data-independent
  # within equal-length inputs.
  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and constant_time_compare(left, right, 0)
  end

  defp constant_time_compare(<<x, left::binary>>, <<y, right::binary>>, acc) do
    import Bitwise
    constant_time_compare(left, right, acc ||| bxor(x, y))
  end

  defp constant_time_compare(<<>>, <<>>, acc), do: acc == 0

  # === Step 1 — structural caller-is-our-orchestrator check ==============
  #
  # Defense-in-depth: the bound orchestrator URI MUST equal the session's
  # DURABLE stored orchestrator (the working-copy field). A stale binding or a
  # session whose orchestrator changed → fail-closed.
  defp structural_check(%__MODULE__{} = binding) do
    with %URI{} = stored <- stored_orchestrator_uri(binding.session_uri),
         true <- URI.to_string(stored) == URI.to_string(binding.orchestrator_uri) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # Read the session's working-copy orchestrator URI from the LIVE Session
  # Kind's `:session` slice (the same-domain canonical reader
  # `Ezagent.Kind.get_slice/2`). SessionManager is materialized alongside the
  # live session, so the live slice is authoritative; we do not re-read the
  # durable snapshot (that path belongs to the cc transport's registration
  # rebuild). Unwraps the Lifecycle two-container `%{state: %{...}}` shape (a
  # flat slice falls through unchanged for any not-yet-converted path).
  defp stored_orchestrator_uri(%URI{} = session_uri) do
    with wc when is_map(wc) <- live_working_copy(session_uri),
         %URI{} = orchestrator_uri <- Map.get(wc, :orchestrator_uri) do
      orchestrator_uri
    else
      _ -> nil
    end
  end

  defp live_working_copy(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: %{template_working_copy: wc}}} when is_map(wc) -> wc
      {:ok, %{template_working_copy: wc}} when is_map(wc) -> wc
      _ -> nil
    end
  end

  # === Step 2 — reconstruct the orchestrator's delegated caps ============
  #
  # Privileged read of the orchestrator agent's OWN `:identity` slice — run
  # SESSION-side so NO caps cross the cc boundary. It grants nothing; the caps
  # are exactly what the Generator delegated. An orchestrator with no delegated
  # caps yields an empty set, and every underlying tool DENIES at the dispatch
  # chokepoint (no admin_caps fallback).
  defp load_orchestrator_caps(%URI{} = orchestrator_uri) do
    Ezagent.Identity.list_caps_for(orchestrator_uri)
  rescue
    _ -> MapSet.new()
  end

  # The caller opts the `Ezagent.Orchestrator.Tools.<tool>` ops consume. The
  # caps are the RECONSTRUCTED orchestrator caps (NOT empty) — the Session
  # chokepoint gates each op with them.
  defp opts(%__MODULE__{} = binding, caps) do
    [
      caller: binding.orchestrator_uri,
      caps: caps,
      session_uri: binding.session_uri,
      workspace_uri: binding.workspace_uri,
      owner: binding.owner_uri || binding.orchestrator_uri,
      parent_template_uri: binding.parent_template_uri
    ]
  end

  # === Step 3 — run the tool (cross-process dispatch to the Session) =====
  #
  # The arg-extraction + op dispatch (relocated verbatim from the old
  # `Ezagent.Orchestrator.ToolRunner`). `arguments` is the LLM's JSON-decoded
  # map (string keys); the caller/cap/session context comes ENTIRELY from
  # `opts`. Returns the tool's raw `{:ok, value}` / `{:error, reason}`.
  defp run_tool_op(:add_managed_member, args, opts) do
    with {:ok, tmpl_uri} <- arg_uri(args, "source_agent_template_uri"),
         {:ok, role_name} <- arg_string(args, "role_name") do
      in_session_template = arg_optional_boolean(args, "in_session_template", true)
      Tools.add_managed_member(tmpl_uri, role_name, in_session_template, opts)
    end
  end

  defp run_tool_op(:update_member_template, args, opts) do
    with {:ok, role_name} <- arg_string(args, "role_name"),
         {:ok, new_tmpl_uri} <- arg_uri(args, "new_source_template_uri") do
      Tools.update_member_template(role_name, new_tmpl_uri, opts)
    end
  end

  defp run_tool_op(:remove_member, args, opts) do
    with {:ok, role_name} <- arg_string(args, "role_name") do
      Tools.remove_member(role_name, opts)
    end
  end

  defp run_tool_op(:define_rule_set_rule, args, opts) do
    with {:ok, matcher} <- arg_matcher(args, "matcher_ast"),
         {:ok, receiver_role} <- arg_string(args, "receiver_role_name"),
         {:ok, rule_set} <- arg_string(args, "rule_set") do
      rule_opts =
        [
          rule_set: rule_set,
          position: arg_optional_integer(args, "position", 0),
          prompt_template_ref: arg_optional_string(args, "prompt_template_ref")
        ] ++ opts

      Tools.define_rule_set_rule(matcher, receiver_role, rule_opts)
    end
  end

  defp run_tool_op(:define_prompt_template, args, opts) do
    with {:ok, name} <- arg_string(args, "name"),
         {:ok, template} <- arg_string(args, "template") do
      Tools.define_prompt_template(name, template, opts)
    end
  end

  defp run_tool_op(:define_legend, args, opts) do
    with {:ok, legend_name} <- arg_string(args, "legend_name"),
         {:ok, member_role_names} <- arg_string_list(args, "member_role_names"),
         {:ok, bound_rule_set} <- arg_string(args, "bound_rule_set") do
      fold = arg_optional_boolean(args, "fold", true)
      Tools.define_legend(legend_name, member_role_names, bound_rule_set, fold, opts)
    end
  end

  defp run_tool_op(:update_template, _args, opts), do: Tools.update_template(opts)

  defp run_tool_op(:save_template_as, args, opts) do
    with {:ok, new_name} <- arg_string(args, "new_name") do
      Tools.save_template_as(new_name, opts)
    end
  end

  defp run_tool_op(:list_templates, args, opts) do
    Tools.list_templates(arg_optional_string(args, "name_filter"), opts)
  end

  # --- tool-name normalization ------------------------------------------

  @doc "The orchestrator tool names (atoms) — delegates to `Tools`."
  @spec tool_names() :: [atom()]
  defdelegate tool_names(), to: Tools

  defp normalize_tool(tool) when is_atom(tool) do
    if Tools.tool?(tool), do: {:ok, tool}, else: {:error, {:unknown_tool, tool}}
  end

  defp normalize_tool(tool) when is_binary(tool) do
    case Enum.find(Tools.tool_names(), &(Atom.to_string(&1) == tool)) do
      nil -> {:error, {:unknown_tool, tool}}
      atom -> {:ok, atom}
    end
  end

  defp normalize_tool(other), do: {:error, {:unknown_tool, other}}

  # --- arg extraction (relocated verbatim from ToolRunner) --------------

  defp arg_string(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp arg_optional_string(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp arg_optional_boolean(args, key, default) do
    case Map.get(args, key) do
      b when is_boolean(b) -> b
      _ -> default
    end
  end

  defp arg_optional_integer(args, key, default) do
    case Map.get(args, key) do
      i when is_integer(i) -> i
      _ -> default
    end
  end

  defp arg_uri(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" ->
        try do
          {:ok, Ezagent.URI.new!(s)}
        rescue
          ArgumentError -> {:error, {:invalid_arg, key}}
        end

      %URI{} = uri ->
        {:ok, uri}

      _ ->
        {:error, {:missing_arg, key}}
    end
  end

  defp arg_string_list(args, key) do
    case Map.get(args, key) do
      list when is_list(list) -> {:ok, Enum.map(list, &to_string/1)}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp arg_matcher(args, key) do
    case Map.get(args, key) do
      %{} = m -> {:ok, m}
      t when is_tuple(t) -> {:ok, t}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  # --- binding construction ---------------------------------------------

  # The three required binding URIs must be present + well-formed; a malformed
  # one is a materialization bug, surfaced as `{:error, {:invalid_uri_opt, …}}`
  # (fail-loud, not silently dropped). The two optional URIs default to nil.
  defp build_binding(opts) do
    with {:ok, orchestrator_uri} <- require_uri(opts, :orchestrator_uri),
         {:ok, session_uri} <- require_uri(opts, :session_uri),
         {:ok, workspace_uri} <- require_uri(opts, :workspace_uri),
         {:ok, owner_uri} <- optional_uri(opts, :owner_uri),
         {:ok, parent_template_uri} <- optional_uri(opts, :parent_template_uri) do
      {:ok,
       %__MODULE__{
         orchestrator_uri: orchestrator_uri,
         session_uri: session_uri,
         workspace_uri: workspace_uri,
         owner_uri: owner_uri,
         parent_template_uri: parent_template_uri
       }}
    end
  end

  defp require_uri(opts, key) do
    case Keyword.get(opts, key) do
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> parse_binding_uri(key, s)
      nil -> {:error, {:missing_opt, key}}
      other -> {:error, {:invalid_uri_opt, key, other}}
    end
  end

  defp optional_uri(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> parse_binding_uri(key, s)
      other -> {:error, {:invalid_uri_opt, key, other}}
    end
  end

  defp parse_binding_uri(key, s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> {:error, {:invalid_uri_opt, key, s}}
  end
end
