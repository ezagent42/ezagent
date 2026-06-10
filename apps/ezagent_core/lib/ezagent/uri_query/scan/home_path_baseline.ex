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
    # P3 (DONE) — the population-3 credential/log/plugin callers all migrated to
    # the `UriQuery` seam (node-global system artifacts → `system://<type>` via
    # `Ezagent.System.FsResolver`, SPEC §10 OI-3). Only the P2-pending uploads
    # entries remain below; when P2 (Allen-gated) lands they too are removed and
    # the baseline reaches the empty terminal state (lockdown complete).
    #
    # P1 (DONE) — the per-agent config-dir now resolves through
    # `Ezagent.Resource.FsResolver` (`resource://<ws>/<ns>-agents/<name>`), whose
    # backend `Home.path/1` call is the sanctioned R-4 chokepoint exempted in
    # `HomePathExceptions`. The raw `Home.path("<ns>-agents")` call is gone from
    # `config_dir.ex`, so its baseline entry is removed (the baseline only ever
    # shrinks, S-3).

    # P2b (DONE) — uploads now store + read through `Ezagent.Resource.FsResolver`
    # (`resource://<ws>/uploads/<name>`, ws-partitioned), whose backend
    # `Home.path/1` call is the sanctioned R-4 chokepoint in `HomePathExceptions`.
    # `Ezagent.Uploads` no longer calls `Home.path(:uploads)`, so its two baseline
    # entries are removed (the baseline only ever shrinks, S-3). The baseline is
    # now empty — lockdown complete (P3 acceptance gate).

    # → P3 (DONE) — the population-3 credential/log/plugin callers (agent_bridge
    # token registry, identity smtp_config, feishu app-cred + inbox + plugin
    # config, python diagnostic log) all migrated to the `UriQuery` seam:
    # node-global system artifacts → `system://<type>` (`Ezagent.System.FsResolver`)
    # per SPEC §10 OI-3. None was a genuine boot-order caller (the one item OI-3
    # flagged — identity's smtp read — runs inside `Application.start/2` AFTER
    # `ezagent_core` seeds the UriQuery tables, so it migrated, not exempted).
    # Their raw `Home` calls are gone, so their baseline entries are removed (the
    # baseline only ever shrinks, S-3).
  ]

  @typedoc "A baseline anchor: `{path, line, call_snippet}`."
  @type t :: {String.t(), pos_integer(), String.t()}

  @doc "All current baselined runtime-app-code raw Home callers (burn-down list)."
  @spec all() :: [t()]
  def all, do: @baseline
end
