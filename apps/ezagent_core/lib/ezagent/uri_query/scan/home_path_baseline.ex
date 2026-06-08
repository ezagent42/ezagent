defmodule Ezagent.UriQuery.Scan.HomePathBaseline do
  @moduledoc """
  Line-anchored burn-down baseline of the CURRENT runtime-app-code raw
  `Ezagent.Home.path/1` / `profile_dir/0` / `home/0` callers that are slated to
  migrate behind `resource://` (Resource-unification SPEC §5.2).

  A baselined call is tolerated ONLY at its recorded `{path, line}` anchor;
  moving or duplicating it fails the `home_path_in_runtime_code` scan category.
  P1/P2/P3 REMOVE entries as each family migrates; the baseline only ever
  SHRINKS (S-3). When empty, the lockdown is complete (P3 acceptance gate).

  This is distinct from `HomePathExceptions`: the baseline lists callers that
  WILL migrate; the exceptions list callers that stay on raw `Home` forever
  (boot / config-eval / operator mix-tasks / OS-handle artifacts).

  Census rebuilt on `origin/main` at P0.5 land time (post-#641 file-flavor
  cascade, post-Phase-3, post-#648 uploads-into-core). The pre-#648 spec/plan
  examples (`admin_live.ex`, `uploads_controller.ex`) no longer hold raw
  `Home.path` calls — uploads now live in `apps/ezagent_core/lib/ezagent/uploads.ex`.

  Each entry: `{relative_path, line, call_snippet}`.
  """

  @baseline [
    # → removed in P1 (per-agent config-dir via resource:// resolver)
    {"apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex", 32,
     "Home.path(\"\#{namespace}-agents\")"},

    # → removed in P2b (uploads via resource:// resolver; #648 moved these into core)
    {"apps/ezagent_core/lib/ezagent/uploads.ex", 40, "Home.path(:uploads)"},
    {"apps/ezagent_core/lib/ezagent/uploads.ex", 75, "Home.path(:uploads)"},

    # → migrated/exempted in P3 (population-3 credential/log/plugin callers)
    {"apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/token_store.ex", 120,
     "Home.path(:credentials)"},
    {"apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex", 143,
     "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex", 164,
     "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex", 176,
     "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex", 414, "Home.profile_dir()"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex", 165,
     "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex", 176,
     "Home.path(:plugins)"},
    {"apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex", 708, "Home.path(:logs)"}
  ]

  @typedoc "A baseline anchor: `{path, line, call_snippet}`."
  @type t :: {String.t(), pos_integer(), String.t()}

  @doc "All current baselined runtime-app-code raw Home callers (burn-down list)."
  @spec all() :: [t()]
  def all, do: @baseline
end
