defmodule EzagentPluginLoom.Tool do
  @moduledoc """
  Tool contract — a named server-side function the loom-UI SDK can RPC
  via `platform.tool(name, args)` → `POST /loom/api/:ws/:sid/tool`.

  Tools are the **white-listed** way for AI-generated pages to reach
  capabilities that the browser sandbox cannot or should not (server
  secrets, external APIs, internal lookups, computations needing
  ESR-side data). The list of available tools is config-driven:

      config :ezagent_plugin_loom, :tools, [
        EzagentPluginLoom.Tools.Echo,
        EzagentPluginLoom.Tools.Now,
        # your own modules implementing this behaviour
      ]

  Each tool module declares its name, an argument schema (for the AI
  prompt — NOT a hard validator, callers may pass extra keys), and a
  `call/2` implementation. Failures should be returned as
  `{:error, reason}` (rendered as `{ok: false, error: ...}` to the
  page), not raised — the WebPlug handler catches raises as a generic
  500 but operators shouldn't rely on that.

  ## Context the handler passes you

      %{
        ws: String.t(),         # workspace segment, e.g. "system"
        sid: String.t(),        # session segment, e.g. "demo1"
        caller: URI.t() | nil,  # caller entity URI (the session's temp UI user)
        session_uri: URI.t()    # session://loom/<ws>/<sid>
      }

  Use this to scope side effects to the session (e.g. write back to
  session slice via dispatch). For tools that are pure functions of
  args (echo, now, fetch wrappers), the ctx is informational only.

  ## Naming

  Names are user-visible to the AI prompt — keep them short and
  dot-namespaced (e.g. `"weather.current"`, `"qcc.lookup"`, `"echo"`).
  Lowercase, no spaces. Must be unique across all configured tools at
  boot (`ToolRegistry.register_all/0` raises on collision).
  """

  @doc "Stable tool name. Used as the RPC selector. Must be unique."
  @callback name() :: String.t()

  @doc """
  Args schema — exposed in the page-generation system prompt so the
  AI knows how to call this tool. Free-form map; convention is:

      %{
        "city" => %{type: "string", required: true, doc: "城市名,如 杭州"},
        "tz" => %{type: "string", default: "Asia/Shanghai"}
      }

  Not used for runtime validation (caller may pass any map). Document
  your own argument handling in `call/2`.
  """
  @callback args_schema() :: map()

  @doc """
  One-line description for the page-generation prompt. Plain text,
  no markdown. The AI uses this + name + args_schema to decide
  whether/how to call your tool.
  """
  @callback description() :: String.t()

  @doc """
  Run the tool. Return `{:ok, result}` (JSON-serializable) on success,
  `{:error, reason}` (atom or string) on failure. Raising is allowed
  but discouraged — the handler will return generic 500 to the page.
  """
  @callback call(args :: map(), ctx :: map()) :: {:ok, term()} | {:error, term()}
end
