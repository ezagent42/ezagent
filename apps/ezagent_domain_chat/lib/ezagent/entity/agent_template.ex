defmodule Ezagent.Entity.AgentTemplate do
  @moduledoc """
  AgentTemplate Kind — what a spawnable Agent looks like (Phase 7
  PR 37).

  Per SPEC D7-2 + Allen 2026-05-18: "AgentTemplate 不需要过于复杂,
  类似 Claude AgentSDK 那样,指定工作目录,加载指定 setting 目录等等".

  An AgentTemplate is a **named, persistent pointer to a sandbox**
  (a directory tree that contains `.claude/settings.json`, MCP config,
  hooks, skills, plugins, credentials) plus a small cap policy.
  Instances are spawned by `Ezagent.Entity.Agent.spawn/4` (PR 40) and
  composed into team configurations by `Ezagent.Entity.SessionTemplate`
  (PR 38). The orchestrator agent (PR 45+) selects from registered
  AgentTemplates via its `list_templates` and `add_agent_slot` tools.

  > **Single source of truth for cc agent sandbox/config.** A
  > standalone `cc-agent-config` SPEC was drafted 2026-05-22 and
  > RETIRED 2026-05-23 (branch `docs/cc-agent-config-spec` deleted,
  > never merged): this slice schema (`config_dir`,
  > `settings_path`, `mcp_config_path`, `api_key_helper`) already
  > covered it. Operator companion runbook:
  > `docs/runbook/cc-agent-config.md`. Future plugin authors
  > extending cc-agent config knobs add fields HERE — not in a
  > parallel store.

  ## URI shape

  `template://agent/<name>` (no version suffix — AgentTemplates are
  human-edited and versionless for now; bump to versioned shape if
  Phase 8+ adds blueprint synthesis or auto-evolution).

  ## `:template` slice content schema (Phase 7 completion PR-1, SPEC §1.0)

  The schema below is the real `Ezagent.Behavior.Template` `:template`
  slice content map — no longer moduledoc-only. `flavor` (SPEC §1.1)
  names the plugin Template Class the `:instantiate` action delegates
  to (`"cc"` → `Ezagent.PluginCc.Template.CcAgent`).

      %{
        # metadata
        name:               String.t(),
        description:        String.t(),

        # delegation target — flavor → Template Class
        flavor:             String.t(),       # "cc" etc.

        # PTY launch params (the flavor Template Class translates these
        # to erlexec env + CLI args when starting the claude process).
        #
        # PR-2 (domain.agent): `working_directory` was split into two clean
        # intents — `project_cwd` (universal: where the agent works / cd's
        # into → "cwd" data key) vs the cc-flavor `config_dir` (the sandbox
        # config-home INPUT → "claude_config_dir" data key; renamed from
        # `claude_config_dir`). `project_cwd` is universal; `config_dir` is
        # cc-flavor-owned (curl/codex have no external config dir).
        project_cwd:        String.t(),       # universal — the project/working dir
        config_dir:         String.t() | nil, # cc only — sandbox config-home input
        settings_path:      String.t() | nil,  # --settings override
        mcp_config_path:    String.t() | nil,  # --mcp-config override
        api_key_helper:     String.t() | nil,  # macOS multi-agent only

        # lineage (PR1 2026-05-24 — Allen: fork lifted to Behavior.Template
        # as a generic Template-Kind concern; AgentTemplate now carries
        # lineage too). nil for ROOT templates; set to the source URI on
        # fork.
        parent_template_uri: URI.t() | nil,

        # ESR side
        default_caps:       [Ezagent.Capability.t()],
        created_by:         URI.t() | nil,
        created_at:         DateTime.t()
      }

  The shape above is the cc-flavor view. Since SPEC
  2026-06-01-flavor-generic-template-data (approach B), the content is a
  UNIVERSAL base (`flavor`, `project_cwd`, `default_caps`,
  `parent_template_uri`, `created_by`, `created_at`) + **flavor-owned
  extras** declared by each flavor's Template Class via
  `c:Ezagent.Kind.Template.template_data_extra/1`. `to_template_data/2`
  stays flavor-agnostic: cc contributes
  `config_dir`/`settings_path`/`mcp_config_path`/`api_key_helper`/`role`;
  curl contributes `provider`/`api_url`/`model`/`system_prompt`/`max_history`;
  codex contributes `model`/`approval_policy`/`sandbox`/… A template missing a
  required flavor field fails loud at `to_template_data/2` (it runs the
  flavor's `validate/1`).

  **What is NOT in a cc AgentTemplate slice** (deliberately): prompt, model,
  effort, tools whitelist, MCP servers — for cc, those live in the pointed-at
  `config_dir` (or the explicit `settings_path` override); ESR doesn't
  re-model what CC already encodes. Other flavors (curl/codex) DO carry their
  provider/model in the slice (they have no external config dir to point at) —
  hence the flavor-owned extras above.

  ## Persistence

  `{:snapshot, :on_change}` — AgentTemplates are durable
  configuration data; restart must restore the same set of
  templates the orchestrator can choose from.

  ## Spawn lifecycle

  AgentTemplate Kinds materialize either:
  - At admin-driven creation time (LV form / `mix
    esr.agent_template.create`) — direct `SpawnRegistry.spawn/1`
    + grant Identity.update_slice with the supplied config.
  - At boot via snapshot reload (ReadyGate replays the slice).

  No automatic spawn on first reference — operators must explicitly
  create AgentTemplates. The cc-orchestrator's seed template is
  installed at boot in dev profile (PR 45 deliverable).

  ## macOS Keychain caveat

  On macOS, CC credentials live in Keychain regardless of
  `CLAUDE_CONFIG_DIR`. Multi-agent on a single OS user shares
  Keychain credential access. Mitigations:
  - Populate `api_key_helper` with a per-template helper script that
    rotates keys (per `docs/onboarding/adding-a-plugin.md` worked
    example, PR 51 deliverable).
  - Or run each agent under a separate OS user.
  - Or accept the shared credential on dev macOS; production runs on
    Linux where `CLAUDE_CONFIG_DIR` fully isolates.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent_template

  # Phase 7 completion PR-1 (SPEC §1.0): AgentTemplate carries TWO
  # slices — `:identity` (the cap policy) and `:template` (the
  # template CONTENT, served via `Ezagent.Behavior.Template`'s
  # dispatchable `:read` / `:write` / `:instantiate` actions).
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Identity, Ezagent.Behavior.Template]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): AgentTemplate Kinds live under
  # the chat domain's AgentTemplateSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.AgentTemplateSupervisor

  @doc """
  Adapter — AgentTemplate `:template` slice content + a per-instance
  agent URI → the cc-flavored Template-Class data map (SPEC §1.5 (b)).

  The plugin Template Class (`Ezagent.PluginCc.Template.CcAgent`)
  consumes a string-keyed map; this is the pure function that produces
  it from the AgentTemplate content. It is flavor-agnostic in shape —
  the `"class"` key resolves from the content's `flavor` via the
  `AgentFlavorRegistry`'s Template Class `template_name/0`.

  Mapping:

  | AgentTemplate content field | cc.agent data key            |
  |-----------------------------|------------------------------|
  | (flavor's Class name)       | `"class"`                    |
  | `instance_agent_uri`        | `"agent_uri"`                |
  | `project_cwd`               | `"cwd"` (required — errors if nil) |
  | `settings_path`             | `"operator_settings_path"`   |
  | `mcp_config_path`           | `"operator_mcp_config_path"` |
  | `config_dir`                | `"claude_config_dir"`        |
  | `api_key_helper`            | `"api_key_helper"`           |

  PR-2 (domain.agent): the universal `project_cwd` (the project/working dir
  the agent runs in — renamed from `working_directory`) and the cc-flavor
  `config_dir` (the sandbox config-home input — renamed from
  `claude_config_dir`) are two distinct intents. The DATA KEYS (`"cwd"`,
  `"claude_config_dir"`) are unchanged — they are the universal flavor
  Template-Class contract.

  The four optional keys are only added when present (a nil value is
  dropped) so the legacy 3-key cc.agent form still validates when the
  AgentTemplate sets none of them.

  Returns `{:ok, data_map}` or `{:error, reason}`.
  """
  @spec to_template_data(map(), URI.t()) :: {:ok, map()} | {:error, term()}
  def to_template_data(content, %URI{} = instance_agent_uri) when is_map(content) do
    # SPEC 2026-06-01-flavor-generic-template-data (approach B): core
    # builds the UNIVERSAL base (class/agent_uri/cwd) and delegates every
    # flavor-specific field to the flavor's Template Class via the optional
    # `template_data_extra/1` callback. Core no longer hardcodes cc's field
    # set — curl's provider/api_url/model + codex's model/sandbox/… are
    # owned by their plugins. (Pre-fix this dropped curl/codex fields, so
    # orchestrator-spawned curl/codex workers had nil provider/model.)
    with {:ok, tc} <- resolve_template_class(content),
         {:ok, cwd} <- fetch_project_cwd(content) do
      base = %{
        "class" => tc.template_name(),
        "agent_uri" => URI.to_string(instance_agent_uri),
        "cwd" => cwd
      }

      extra =
        if function_exported?(tc, :template_data_extra, 1) do
          tc.template_data_extra(content)
        else
          %{}
        end

      data = merge_template_extra(base, extra)

      # Fail-fast (codex review HIGH): a misconfigured flavor template
      # (e.g. curl missing provider) must NOT spawn a nil-config worker.
      # The spawn path does not call validate/1 before instantiate, so we
      # do it here against the flavor's OWN rules.
      case validate_for_flavor(tc, data) do
        :ok -> {:ok, data}
        {:error, reason} -> {:error, {:invalid_template_data, reason}}
      end
    end
  end

  def to_template_data(content, _uri), do: {:error, {:invalid_template_content, content}}

  # Reserved universal keys core owns — a flavor's template_data_extra/1
  # must never override these.
  @reserved_template_data_keys ~w(class agent_uri cwd)

  # Merge the flavor's extras onto the base: stringify keys, drop nil
  # values, and refuse reserved-key overrides (defensive — the callback
  # contract already forbids them).
  defp merge_template_extra(base, extra) when is_map(extra) do
    Enum.reduce(extra, base, fn {k, v}, acc ->
      ks = to_string(k)

      cond do
        is_nil(v) -> acc
        ks in @reserved_template_data_keys -> acc
        true -> Map.put(acc, ks, v)
      end
    end)
  end

  defp merge_template_extra(base, _not_a_map), do: base

  defp validate_for_flavor(tc, data) do
    if function_exported?(tc, :validate, 1), do: tc.validate(data), else: :ok
  end

  # Resolve the flavor's Template Class MODULE from content (ONE registry
  # lookup — reused for `class`, `template_data_extra/1`, and `validate/1`;
  # codex review LOW: no double lookup).
  defp resolve_template_class(content) do
    case content_get(content, :flavor) do
      flavor when is_binary(flavor) and flavor != "" ->
        case Ezagent.AgentFlavorRegistry.lookup(flavor) do
          {:ok, %{template_class: tc}} -> {:ok, tc}
          :error -> {:error, {:unknown_flavor, flavor}}
        end

      _ ->
        {:error, :missing_flavor}
    end
  end

  # PR-2 (domain.agent): `project_cwd` is the universal "where the agent works /
  # cd's into" intent — the project directory, distinct from the cc-flavor
  # `config_dir` (the sandbox config-home input). It maps to the universal
  # `"cwd"` data key every flavor Template Class consumes.
  defp fetch_project_cwd(content) do
    case content_get(content, :project_cwd) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> {:error, :missing_project_cwd}
    end
  end

  # The content map may carry atom OR string keys (atom keys from
  # freshly-built content, string keys after a JSON snapshot round-trip).
  defp content_get(content, key) when is_atom(key) do
    case Map.get(content, key) do
      nil -> Map.get(content, Atom.to_string(key))
      value -> value
    end
  end

  @doc """
  Fork an AgentTemplate — `fork(parent_uri, new_name, opts)` (PR1
  2026-05-24, Allen architectural decision: fork is a generic
  Template-Kind concern).

  Configuration-only fork: the new AgentTemplate carries the parent's
  content + `parent_template_uri: parent_uri` lineage. The destination
  URI is `template://agent/<workspace>/<new_name>` (versionless, inherits
  parent's workspace).

  ## What it does

  Delegates entirely to `Ezagent.Behavior.Template.invoke(:fork, ...)`
  via dispatch — the real fork orchestration (parent content read, fork
  content build, persist, owner-cap grant) lives there. This module
  function exists for API symmetry with `SessionTemplate.fork/3` and to
  give callers a typed, discoverable entry point.

  ## Options

  - `:caps` — the caller's cap set (`MapSet`/list of `Capability.t()`).
    Required — dispatch CapBAC checks `Behavior.Template` against the
    parent URI's workspace.
  - `:caller` — `%URI{}` of the principal performing the fork. Required.
  - `:owner` — `%URI{}` to receive the owner cap. Defaults to `:caller`.

  ## Returns

  - `{:ok, new_template_uri}` — the fork's
    `template://agent/<ws>/<new_name>` URI.
  - `{:error, :unauthorized}` / `{:error, :template_not_populated}` /
    other dispatch error.

  Does NOT spawn an agent — instantiation goes through
  `Behavior.Template :instantiate` on the new template URI, which the
  caller invokes separately.
  """
  @spec fork(URI.t(), String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def fork(%URI{} = parent_uri, new_name, opts \\ [])
      when is_binary(new_name) and new_name != "" do
    with {:ok, caps} <- fetch_opt(opts, :caps),
         {:ok, %URI{} = caller_uri} <- fetch_opt(opts, :caller),
         {:ok, _pid} <- ensure_kind_alive(parent_uri) do
      args = %{
        new_name: new_name,
        owner: Keyword.get(opts, :owner, caller_uri)
      }

      ctx = %{
        caller: caller_uri,
        caps: normalize_caps_set(caps),
        reply: {:caller_inbox, self()}
      }

      target = Ezagent.URI.new!("#{URI.to_string(parent_uri)}?action=template.fork")

      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: args,
             ctx: ctx
           }) do
        {:ok, %{template_uri: %URI{} = uri}} -> {:ok, uri}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_fork_result, other}}
      end
    end
  end

  # --- shim internals ----------------------------------------------------

  defp fetch_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  defp ensure_kind_alive(uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  defp normalize_caps_set(%MapSet{} = caps), do: caps
  defp normalize_caps_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp normalize_caps_set(_), do: MapSet.new()
end
