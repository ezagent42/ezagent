defmodule Ezagent.Orchestrator.ToolRunner do
  @moduledoc """
  Value-form core that runs ONE orchestrator tool operation against a
  caller context — the session-domain operation layer beneath the cc MCP
  transport.

  ## Why this lives in `domain.session` (im), not the cc plugin

  The 7 orchestrator tools (`Ezagent.Orchestrator.Tools`) MUTATE session +
  routing state — they are session-domain operations (decomposition spec
  §3.4 / OQ-2: "transport → cc, operations → session"). The cc plugin owns
  only the MCP TRANSPORT (decode the wire `tools/call`, forward, encode the
  result). This module is the operation core the transport forwards INTO via
  `Ezagent.Invocation.dispatch` (a runtime edge cc → session, NOT a compile
  dependency).

  ## What it does

  Given a normalized `tool` atom, the LLM-supplied `arguments` map (string
  keys), and a caller `opts` keyword list (`:caller`, `:caps`,
  `:session_uri`, `:workspace_uri`, `:owner`, `:parent_template_uri`), it
  extracts the operation-shaped args and calls the matching
  `Ezagent.Orchestrator.Tools.<tool>` function with those opts.

  The `opts` carry the caller URI + the orchestrator's FOUR delegated caps
  as `ctx.caps`. Those caps gate each underlying op AT THE DISPATCH
  CHOKEPOINT (Invariant #19); a missing delegated cap returns
  `{:error, :unauthorized}` — fail-closed, NEVER a fallback to ambient
  `admin_caps`. **This module performs NO authorization itself** — it is the
  pure operation runner. The caller URI + caps MUST be supplied by an
  authorized caller (the session-side `Ezagent.Behavior.OrchestratorTools`
  action handler, which reconstructs them session-side after a structural
  caller-is-our-orchestrator check — O-4). The `opts` arrive verbatim from
  that handler; nothing here trusts a wire value.

  Returns the raw `{:ok, value}` / `{:error, reason}` the tool produced —
  the MCP-shaped ENCODING of that result is the cc transport's job
  (`Ezagent.Orchestrator.McpServer`).
  """

  alias Ezagent.Orchestrator.Tools

  @doc "The 9 orchestrator tool names (atoms) — delegates to `Tools`."
  @spec tool_names() :: [atom()]
  defdelegate tool_names(), to: Tools

  @doc "True iff `name` is a declared orchestrator tool — delegates to `Tools`."
  @spec tool?(atom()) :: boolean()
  defdelegate tool?(name), to: Tools

  @doc """
  Normalize a wire tool name (string or atom) to the known tool atom, or
  `nil` when it is not one of the declared tools. The cc transport uses this
  to map a `tools/call` `tool` field before forwarding.
  """
  @spec normalize_tool(String.t() | atom()) :: atom() | nil
  def normalize_tool(tool) when is_atom(tool) do
    if Tools.tool?(tool), do: tool, else: nil
  end

  def normalize_tool(tool) when is_binary(tool) do
    Enum.find(Tools.tool_names(), &(Atom.to_string(&1) == tool))
  end

  def normalize_tool(_), do: nil

  @doc """
  Run the named tool against the caller `opts`. `tool` MUST be a known tool
  atom (use `normalize_tool/1` first). `arguments` is the JSON-decoded
  argument map (string keys); the caller / cap / session context comes
  ENTIRELY from `opts` — the arguments carry only operation-shaped fields.

  Returns the tool's raw `{:ok, value}` / `{:error, reason}`.
  """
  @spec run_tool(atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_tool(:add_managed_member, args, opts) do
    with {:ok, tmpl_uri} <- arg_uri(args, "source_agent_template_uri"),
         {:ok, role_name} <- arg_string(args, "role_name") do
      in_session_template = arg_optional_boolean(args, "in_session_template", true)
      Tools.add_managed_member(tmpl_uri, role_name, in_session_template, opts)
    end
  end

  def run_tool(:update_member_template, args, opts) do
    with {:ok, role_name} <- arg_string(args, "role_name"),
         {:ok, new_tmpl_uri} <- arg_uri(args, "new_source_template_uri") do
      Tools.update_member_template(role_name, new_tmpl_uri, opts)
    end
  end

  def run_tool(:remove_member, args, opts) do
    with {:ok, role_name} <- arg_string(args, "role_name") do
      Tools.remove_member(role_name, opts)
    end
  end

  def run_tool(:define_rule_set_rule, args, opts) do
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

  def run_tool(:define_prompt_template, args, opts) do
    with {:ok, name} <- arg_string(args, "name"),
         {:ok, template} <- arg_string(args, "template") do
      Tools.define_prompt_template(name, template, opts)
    end
  end

  def run_tool(:define_legend, args, opts) do
    with {:ok, legend_name} <- arg_string(args, "legend_name"),
         {:ok, member_role_names} <- arg_string_list(args, "member_role_names"),
         {:ok, bound_rule_set} <- arg_string(args, "bound_rule_set") do
      fold = arg_optional_boolean(args, "fold", true)
      Tools.define_legend(legend_name, member_role_names, bound_rule_set, fold, opts)
    end
  end

  def run_tool(:update_template, _args, opts) do
    Tools.update_template(opts)
  end

  def run_tool(:save_template_as, args, opts) do
    with {:ok, new_name} <- arg_string(args, "new_name") do
      Tools.save_template_as(new_name, opts)
    end
  end

  def run_tool(:list_templates, args, opts) do
    Tools.list_templates(arg_optional_string(args, "name_filter"), opts)
  end

  # --- arg extraction (moved verbatim from McpServer) --------------------

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
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue to preserve the `{:error, _}` contract for
        # malformed MCP args.
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

  # The matcher arg may arrive as a JSON map OR a 2-tuple (test form).
  defp arg_matcher(args, key) do
    case Map.get(args, key) do
      %{} = m -> {:ok, m}
      t when is_tuple(t) -> {:ok, t}
      _ -> {:error, {:missing_arg, key}}
    end
  end
end
