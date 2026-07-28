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
  composed into team configurations by the session-side template Kind
  (PR 38). The orchestrator agent (PR 45+) selects from registered
  AgentTemplates via its `list_templates` and `add_agent_slot` tools.

  > **Single source of truth for cc agent sandbox/config.** A
  > standalone `cc-agent-config` SPEC was drafted 2026-05-22 and
  > RETIRED 2026-05-23 (branch `docs/cc-agent-config-spec` deleted,
  > never merged): this slice schema (`config_dir` — now universal,
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

  The schema below is the real `Ezagent.ActionSet.Template` `:template`
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
        # into → "cwd" data key) vs `config_dir` (the per-agent config-home
        # INPUT → "config_dir" data key; renamed from `claude_config_dir`).
        # Both are UNIVERSAL.
        #
        # config_dir promotion (Allen 2026-06-03): the CONCEPT "every agent
        # has a per-agent config home directory" is universal — every flavor
        # (cc/codex/curl/echo/np) gets a `config_dir`. Only the CONTENTS /
        # file-format of that dir are flavor-specific: the cc Template Class
        # reads the universal `config_dir` and applies claude semantics (sets
        # `CLAUDE_CONFIG_DIR`, writes `.claude.json` / `settings.json` /
        # `.credentials.json` there). codex/curl/echo just receive a
        # `config_dir` they may use per their own format. This is consistent
        # with approach B (SPEC 2026-06-01-flavor-generic-template-data): the
        # DIRECTORY concept is universal; the cc FILE FORMAT stays cc-owned.
        project_cwd:        String.t(),       # universal — the project/working dir
        config_dir:         String.t() | nil, # universal — per-agent config-home input
        settings_path:      String.t() | nil,  # --settings override
        mcp_config_path:    String.t() | nil,  # --mcp-config override
        api_key_helper:     String.t() | nil,  # macOS multi-agent only

        # lineage (PR1 2026-05-24 — Allen: fork lifted to Behavior.Template
        # as a generic Template-Kind concern; AgentTemplate now carries
        # lineage too). nil for ROOT templates; set to the source URI on
        # fork.
        parent_template_uri: URI.t() | nil,

        # Ezagent side
        default_caps:       [Ezagent.Capability.t()],

        # DOMAIN-owned desired skills/caps (PR-6, domain.agent). The DOMAIN
        # (not the plugin) declares what a member built from this template
        # SHOULD have. `desired_skills` are flavor-agnostic skill NAMES placed
        # into the agent's config_dir by the flavor's instantiate/3;
        # `desired_caps` are caps granted to the spawned member identity at the
        # re-materialization seam (shared with PR-5 reconfigure). Distinct from
        # `default_caps` (the template Kind's STRUCTURAL cap policy / fork
        # baseline). Both UNIVERSAL (flavor-agnostic); both optional (omitted
        # from to_template_data/2 when absent). See
        # docs/notes/pr6-desired-skills-caps.md.
        desired_skills:     [String.t()] | nil,
        desired_caps:       [Ezagent.Capability.t()] | nil,

        created_by:         URI.t() | nil,
        created_at:         DateTime.t()
      }

  The shape above is the cc-flavor view. Since SPEC
  2026-06-01-flavor-generic-template-data (approach B), the content is a
  UNIVERSAL base (`flavor`, `project_cwd`, `config_dir`, `default_caps`,
  `parent_template_uri`, `created_by`, `created_at`) + **flavor-owned
  extras** declared by each flavor's Template Class via
  `c:Ezagent.Kind.Template.template_data_extra/1`. `to_template_data/2`
  stays flavor-agnostic: it emits the universal base (incl. the neutral
  `config_dir` data key) and cc contributes only its flavor extras
  `settings_path`/`mcp_config_path`/`api_key_helper`/`role`;
  curl contributes `provider`/`api_url`/`model`/`system_prompt`/`max_history`;
  codex contributes `model`/`approval_policy`/`sandbox`/… A template missing a
  required flavor field fails loud at `to_template_data/2` (it runs the
  flavor's `validate/1`).

  > **config_dir is UNIVERSAL (Allen 2026-06-03).** Every flavor has a
  > per-agent config home dir; the universal base emits a flavor-NEUTRAL
  > `"config_dir"` data key. The cc Template Class READS that neutral key
  > and applies claude-specific semantics (`CLAUDE_CONFIG_DIR`,
  > `.claude.json`/`settings.json`/`.credentials.json`). codex/curl/echo
  > receive the same `"config_dir"` and use it per their own format. There
  > is NO cc-named `"claude_config_dir"` data key — the universal concept
  > carries the neutral name (no back-compat shim; DB is wiped + rebuilt).

  **What is NOT in a cc AgentTemplate slice** (deliberately): prompt, model,
  effort, tools whitelist, MCP servers — for cc, those live in the pointed-at
  `config_dir` (or the explicit `settings_path` override); Ezagent doesn't
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
  # template CONTENT, served via `Ezagent.ActionSet.Template`'s
  # dispatchable `:read` / `:write` / `:instantiate` actions).
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.Template]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): AgentTemplate Kinds live under
  # the chat domain's AgentTemplateSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainInstanceMessage.AgentTemplateSupervisor

  @doc """
  Compute a content hash for an AgentTemplate version.

  AgentTemplate's historical root URI remains versionless, but migrations need
  edited member sources to mint a distinct immutable URI so
  `update_member_template/3` can spawn-new before retiring the old worker.
  """
  @spec compute_version_hash(map()) :: String.t()
  def compute_version_hash(content) when is_map(content) do
    content
    |> Map.drop([:created_at, :created_by, :version_hash, :version_tag, :name])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Build a hash-addressed AgentTemplate URI: `template://<ws>/agent/<name>@<hash>`."
  @spec build_versioned_uri(String.t(), String.t(), keyword()) :: URI.t()
  def build_versioned_uri(name, version_hash, opts \\ [])
      when is_binary(name) and is_binary(version_hash) do
    workspace =
      Keyword.get(opts, :workspace) ||
        raise ArgumentError,
              "Ezagent.Entity.AgentTemplate.build_versioned_uri/3 requires opts[:workspace]"

    Ezagent.URI.template(workspace, :agent, "#{name}@#{version_hash}")
  end

  @doc """
  Persist a hash-addressed AgentTemplate version under the bootstrap principal.

  This is the mainline semantic seam for spec-3's "per-edit version minting".
  Authoring/front-end publish code may wrap it with stricter caller-threaded
  auth, but migration consumes only the resulting immutable source URI.
  """
  @spec persist_version_as_system(map(), URI.t() | String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def persist_version_as_system(content, workspace) when is_map(content) do
    name = Map.get(content, :name) || Map.get(content, "name")
    workspace_segment = workspace_segment(workspace)

    cond do
      not (is_binary(name) and name != "") ->
        {:error, :missing_template_name}

      is_nil(workspace_segment) ->
        {:error, :invalid_workspace}

      true ->
        hash = compute_version_hash(content)
        uri = build_versioned_uri(name, hash, workspace: workspace_segment)
        versioned_content = Map.put(content, :version_hash, hash)

        with {:ok, _pid} <- ensure_kind_alive(uri),
             {:ok, _result} <- dispatch_write_as_system(uri, versioned_content) do
          {:ok, uri}
        end
    end
  end

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
  | (flavor's Class name)       | universal data key           |
  |-----------------------------|------------------------------|
  | (flavor's Class name)       | `"class"`                    |
  | `instance_agent_uri`        | `"agent_uri"`                |
  | `project_cwd`               | `"cwd"` (required — errors if nil) |
  | `config_dir`                | `"config_dir"` (universal, neutral; nil dropped) |

  cc flavor extras (`template_data_extra/1`):

  | AgentTemplate content field | cc data key                  |
  |-----------------------------|------------------------------|
  | `settings_path`             | `"operator_settings_path"`   |
  | `mcp_config_path`           | `"operator_mcp_config_path"` |
  | `api_key_helper`            | `"api_key_helper"`           |
  | `role`                      | `"role"`                     |

  PR-2 (domain.agent) + config_dir promotion (Allen 2026-06-03): the
  universal `project_cwd` (the project/working dir the agent runs in —
  renamed from `working_directory`) and the universal `config_dir` (the
  per-agent config-home input — renamed from `claude_config_dir`) are two
  distinct intents emitted in the universal base under the flavor-NEUTRAL
  data keys `"cwd"` and `"config_dir"`. The cc Template Class READS the
  neutral `"config_dir"` and applies its claude semantics; there is no
  cc-named `"claude_config_dir"` data key.

  `config_dir` is only added when present (a nil value is dropped) so the
  legacy 3-key cc.agent form still validates when the AgentTemplate sets
  it to nil.

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
         {:ok, flavor} <- fetch_flavor(content),
         {:ok, cwd} <- fetch_project_cwd(content),
         {:ok, config_dir} <- fetch_config_dir(content),
         {:ok, cascade} <- fetch_cascade(content),
         {:ok, extra} <- template_extra(tc, content) do
      # config_dir promotion (PR-2, Allen 2026-06-03): config_dir is UNIVERSAL —
      # every flavor's config-home dir is emitted here under the neutral
      # `"config_dir"` data key. nil ⇒ dropped. The cc Template Class reads this
      # neutral key and applies its claude semantics.
      base =
        %{
          "class" => tc.template_name(),
          "agent_uri" => Ezagent.URI.stable_key(instance_agent_uri),
          "cwd" => cwd,
          # #201 PR-2 — the AUTHORITATIVE instantiate-time flavor. The global
          # `AgentFlavorAttributes` ETS row is no longer written before the
          # spawn winner is known, so an `instantiate/3` that needs its flavor
          # reads it HERE (in-process data), never from the global table.
          "flavor" => flavor
        }
        |> put_config_dir(config_dir)
        # #17 cascade PR-3 — activate the PR-2 materializer by threading the
        # domain-resolved cascade inputs into the flavor Template Class data.
        # The cc/codex Template Classes consume `"cascade"` when present and
        # otherwise keep the existing single-reference materialize path.
        |> put_cascade(cascade)
        # #17 PR-4 - in-process flavors (curl) materialize the selected
        # credential into a slice, not files. They need the selected
        # credential source URI from the domain-resolved cascade resolution.
        |> put_cascade_resolution(content)
        # PR-6 (domain.agent) — DOMAIN-owned desired skills/caps. UNIVERSAL
        # (flavor-agnostic) content fields the DOMAIN declares for a member built
        # from this template; they ride into the Template-Class data map so a
        # flavor's instantiate/3 can place the skills + the domain spawn/regenerate
        # path can grant the caps. Absent → omitted. Reads atom OR string keys.
        |> put_universal_desired(content, :desired_skills)
        |> put_universal_desired(content, :desired_caps)

      data =
        base
        |> merge_template_extra(extra)
        |> merge_template_extra(config_schema_extra(tc, content))

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
  # must never override these. `config_dir` is universal (Allen
  # 2026-06-03), so a flavor extra can't shadow it either. `flavor` is the
  # #201 PR-2 authoritative instantiate-time flavor, so an extra can't
  # shadow THAT either.
  @reserved_template_data_keys ~w(class agent_uri cwd config_dir cascade cascade_resolution flavor)

  # config_dir promotion (Allen 2026-06-03): validate the universal config
  # home dir.
  #
  # - absent / nil  ⇒ `{:ok, nil}` (LEGITIMATE: the agent runs without a
  #   config home — for cc that means claude reads `~/.claude`).
  # - non-empty binary ⇒ `{:ok, dir}`.
  # - present-but-malformed (non-binary, or "") ⇒ FAIL LOUD (codex P2): a
  #   misconfigured config_dir must NOT be silently dropped (which would
  #   spawn the agent without its isolated config dir). Per
  #   `feedback_let_it_crash_no_workarounds` we return a structured error
  #   rather than degrade. Mirrors cc's `check_optional_sandbox_keys/1`,
  #   which fails loud on a malformed (present) sandbox key.
  defp fetch_config_dir(content) do
    # codex P2 closure — also fail loud on a STALE content-level
    # `claude_config_dir` field. A content map that uses the new
    # `project_cwd` but still carries the OLD `claude_config_dir` field would
    # otherwise be silently ignored here (config_dir reads as absent) and the
    # cc agent would spawn without its isolated `CLAUDE_CONFIG_DIR`. Reject
    # it structurally (no shim) so the misconfiguration is visible.
    cond do
      has_stale_config_dir_field?(content) ->
        {:error,
         {:stale_config_dir_field, :claude_config_dir,
          "config_dir is now the universal content field (Allen 2026-06-03); " <>
            "rename `claude_config_dir` → `config_dir`. No back-compat shim."}}

      true ->
        case content_get(content, :config_dir) do
          nil -> {:ok, nil}
          dir when is_binary(dir) and dir != "" -> {:ok, dir}
          bad -> {:error, {:invalid_config_dir, bad}}
        end
    end
  end

  # The stale field may be present under either an atom or a string key
  # (atom for freshly-built content, string after a JSON snapshot round-trip).
  defp has_stale_config_dir_field?(content) do
    Map.has_key?(content, :claude_config_dir) or Map.has_key?(content, "claude_config_dir")
  end

  # Emit the neutral `"config_dir"` data key only when a config home is set.
  defp put_config_dir(base, nil), do: base
  defp put_config_dir(base, dir) when is_binary(dir), do: Map.put(base, "config_dir", dir)

  defp fetch_cascade(content) do
    case content_get(content, :cascade) do
      nil -> {:ok, nil}
      cascade when is_map(cascade) -> {:ok, cascade}
      bad -> {:error, {:invalid_cascade, bad}}
    end
  end

  defp put_cascade(base, nil), do: base
  defp put_cascade(base, cascade) when is_map(cascade), do: Map.put(base, "cascade", cascade)

  defp put_cascade_resolution(base, content) do
    case content_get(content, :cascade_resolution) do
      resolution when is_map(resolution) -> Map.put(base, "cascade_resolution", resolution)
      _ -> base
    end
  end

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

  defp config_schema_extra(tc, content) do
    if function_exported?(tc, :config_schema, 0) do
      tc.config_schema()
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn field, acc ->
        case Map.get(field, :key) do
          key when is_binary(key) and key != "" ->
            case content_config_get(content, key) do
              nil -> acc
              value -> Map.put(acc, key, value)
            end

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  end

  defp template_extra(tc, content) do
    case manifest_compile_payload(content) do
      {:ok, resolved, params} ->
        if function_exported?(tc, :compile, 2) do
          tc.compile(resolved, params)
        else
          {:error, {:compile_not_supported, tc}}
        end

      :none ->
        if function_exported?(tc, :template_data_extra, 1) do
          {:ok, tc.template_data_extra(content)}
        else
          {:ok, %{}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp manifest_compile_payload(content) do
    resolved = content_get(content, :agent_manifest_resolved)
    params = content_get(content, :agent_manifest_params)

    cond do
      is_nil(resolved) and is_nil(params) ->
        :none

      is_map(resolved) and (is_nil(params) or is_map(params)) ->
        {:ok, resolved, params || %{}}

      true ->
        {:error, {:invalid_agent_manifest_compile_payload, resolved, params}}
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

  # PR-6 — add a DOMAIN-owned desired field (skills/caps) to the
  # Template-Class data map under its string key, ONLY when the content
  # carries it. Absent / nil → leave the data map untouched (no empty key),
  # mirroring the four optional cc keys. `key` is the universal content
  # field name (atom); the data-map key is its string form.
  defp put_universal_desired(data, content, key) when is_atom(key) do
    case content_get(content, key) do
      nil -> data
      value -> Map.put(data, Atom.to_string(key), value)
    end
  end

  @doc """
  Resolve a template `content` map's `:flavor` to its Template Class module via
  `Ezagent.AgentFlavorRegistry`: `{:ok, module}` / `{:error, {:unknown_flavor, f}}`
  / `{:error, :missing_flavor}`.

  PR-9 A2 (2026-06-14): relocated here from the session domain's template
  resolver so the agent domain (`AgentTemplate` + its `TemplateSpawn`) no longer
  reaches into the session domain to resolve its own flavor → Template Class —
  cutting an agent→session compile edge for the PR-9 domain split. Depends only
  on the core `AgentFlavorRegistry`.
  """
  @spec resolve_template_class(map()) :: {:ok, module()} | {:error, term()}
  def resolve_template_class(content) when is_map(content) do
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

  # #201 PR-2 — extract the raw content flavor for the authoritative
  # `"flavor"` data key (same shape rules as `resolve_template_class/1`).
  defp fetch_flavor(content) when is_map(content) do
    case content_get(content, :flavor) do
      flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      _ -> {:error, :missing_flavor}
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

  defp content_config_get(content, key) when is_binary(key) do
    case Map.fetch(content, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom(key) do
          {:ok, atom} -> Map.get(content, atom)
          :error -> nil
        end
    end
  end

  defp existing_atom(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
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

  Delegates entirely to `Ezagent.ActionSet.Template.invoke(:fork, ...)`
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
        authenticated_principal: caller_uri,
        caps: normalize_caps_set(caps),
        reply: {:caller_inbox, self()}
      }

      target = Ezagent.URI.new!("#{URI.to_string(parent_uri)}?action=template.fork")

      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: args,
             ctx: ctx,
             origin: :trusted_internal
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

  defp dispatch_write_as_system(%URI{} = uri, content) do
    target = Ezagent.URI.with_action(uri, :template, :write)
    admin = Ezagent.URI.user(:system, :admin)

    with {:ok, signed_cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{content: content},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([signed_cap]),
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })
    end
  end

  defp workspace_segment(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.name!(uri)

  # Accept either a full `workspace://<name>` URI string or an already-bare
  # `<name>`. Parse-and-extract when it is a workspace URI; otherwise it is
  # already the bare segment. (Avoids a raw `workspace://` literal — uri_query gate.)
  defp workspace_segment(workspace) when is_binary(workspace) do
    case Ezagent.URI.parse(workspace) do
      {:ok, %URI{scheme: "workspace"} = uri} -> Ezagent.URI.name!(uri)
      _ -> workspace
    end
  end

  defp workspace_segment(_), do: nil

  defp normalize_caps_set(%MapSet{} = caps), do: caps
  defp normalize_caps_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp normalize_caps_set(_), do: MapSet.new()
end
