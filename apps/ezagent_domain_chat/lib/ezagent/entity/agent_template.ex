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
  > never merged): this slice schema (`claude_config_dir`,
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
        # to erlexec env + CLI args when starting the claude process)
        working_directory:  String.t(),
        claude_config_dir:  String.t() | nil,
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

  **What is NOT in the slice** (deliberately): prompt, model, effort,
  tools whitelist, MCP servers. All of those live in the pointed-at
  `claude_config_dir` (or the explicit `settings_path` override).
  ESR doesn't re-model what CC already encodes — AgentTemplate is a
  sandbox pointer + cap policy, not a full agent spec.

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
  | `working_directory`         | `"cwd"` (required — errors if nil) |
  | `settings_path`             | `"operator_settings_path"`   |
  | `mcp_config_path`           | `"operator_mcp_config_path"` |
  | `claude_config_dir`         | `"claude_config_dir"`        |
  | `api_key_helper`            | `"api_key_helper"`           |

  The four optional keys are only added when present (a nil value is
  dropped) so the legacy 3-key cc.agent form still validates when the
  AgentTemplate sets none of them.

  Returns `{:ok, data_map}` or `{:error, reason}`.
  """
  @spec to_template_data(map(), URI.t()) :: {:ok, map()} | {:error, term()}
  def to_template_data(content, %URI{} = instance_agent_uri) when is_map(content) do
    with {:ok, class} <- resolve_class_name(content),
         {:ok, cwd} <- fetch_working_directory(content) do
      base = %{
        "class" => class,
        "agent_uri" => URI.to_string(instance_agent_uri),
        "cwd" => cwd
      }

      optional = %{
        "operator_settings_path" => content_get(content, :settings_path),
        "operator_mcp_config_path" => content_get(content, :mcp_config_path),
        "claude_config_dir" => content_get(content, :claude_config_dir),
        "api_key_helper" => content_get(content, :api_key_helper)
      }

      data =
        Enum.reduce(optional, base, fn
          {_k, nil}, acc -> acc
          {k, v}, acc -> Map.put(acc, k, v)
        end)

      {:ok, data}
    end
  end

  def to_template_data(content, _uri), do: {:error, {:invalid_template_content, content}}

  # The `"class"` key — the flavor's Template Class `template_name/0`,
  # resolved through `Ezagent.AgentFlavorRegistry`.
  defp resolve_class_name(content) do
    case content_get(content, :flavor) do
      flavor when is_binary(flavor) and flavor != "" ->
        case Ezagent.AgentFlavorRegistry.lookup(flavor) do
          {:ok, %{template_class: tc}} -> {:ok, tc.template_name()}
          :error -> {:error, {:unknown_flavor, flavor}}
        end

      _ ->
        {:error, :missing_flavor}
    end
  end

  defp fetch_working_directory(content) do
    case content_get(content, :working_directory) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> {:error, :missing_working_directory}
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

      target = URI.parse("#{URI.to_string(parent_uri)}?action=template.fork")

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
