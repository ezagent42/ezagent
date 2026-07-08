defmodule Ezagent.PluginCc.Template.OrchestratorBootstrap do
  @moduledoc """
  Install a **role** into a cc agent's `config_dir` (task #54 PR-2; generalized
  for ANY role by Phase 3 ③ T2, 2026-06-28).

  This is the cc-flavor *loader* for a role: it takes the flavor-agnostic role
  recipe (composed via the `Ezagent.Agent.Recipe` core primitives) and writes its
  sandbox **content** into whatever `config_dir` the cc flavor allocated —
  flavor-blind by construction, so the same role would compose against a future
  `codex`/`curl` flavor.

  ## Generalized over the agent's actual role (T2)

  `bootstrap/2` keys off the template's `"role"` field (NOT a hardcoded
  `"orchestrator"` literal): it looks the agent's actual role up BY NAME in
  `Ezagent.Agent.RecipeRegistry` and installs whatever skills that recipe yields.
  The orchestrator is now just the role whose name is `"orchestrator"` — it
  resolves + installs through the SAME path as a `pm`/`dev-together`/any-other cc
  role. An absent / `"default"` role is a `:ok` no-op (every legacy cc agent
  unaffected). This generalizes the **skill-install half only** — any role's
  `skills` now land in `config_dir`.

  ⚠️ NOT end-to-end yet: the template-VALIDATE gate `CcAgent.check_role`
  (`cc_agent.ex:352`) still accepts only `default`/`orchestrator`, so a cc
  template with role `pm`/`dev-together` is rejected at validate and never
  reaches this generalized bootstrap. cc-headless × non-orchestrator-role
  end-to-end create needs `check_role` also generalized (Phase 3 ③ T4/T5/T6;
  Phase 5 closing hard-line — else this is dead code for non-orchestrator roles).

  ## resolve / install split (the migration)

  Two stages, decoupled so the dispatch-free recipe read is testable apart from
  the filesystem install:

  - `resolve_role/1` — look the role recipe up BY NAME in
    `Ezagent.Agent.RecipeRegistry` (populated at cc plugin boot from `roles/0`, RF-9)
    and compose it → `sandbox_content` (`%{skills, plugins, prompt}`). The
    registry IS the re-point seam: a later PR swaps the lookup source to the
    persisted `template://system/recipe/<name>` Template without touching the
    installer. `resolve_orchestrator_recipe/0` is the back-compat alias
    (`resolve_role(OrchestratorRecipe.name())`).
  - `install_role_sandbox/2` — PURE filesystem: for each `skills` ref, resolve its
    source dir + copy it into `config_dir/skills/<ref>`, then append the cc
    skill-load hint to `CLAUDE.md`. No hardcoded skill: it installs whatever the
    composed role yields (already role-agnostic pre-T2).

  The role's `prompt` (the persona) is **not** installed here — it rides the
  agent's seed sandbox `CLAUDE.md`, which `Ezagent.Credential.HomeRuntime` copies
  into each per-agent `config_dir`; writing it here would duplicate it.

  A `nil` config_dir or an absent / `"default"` role is a `:ok` no-op. A copy /
  source-resolution / recipe failure returns `{:error, _}` (see `try_apply/3` for
  the best-effort spawn-path wrapper).

  ## Deferred (PR-2 scope)

  `behaviors`/`caps`→`TemplateSpawn` threading and the forkable persisted role
  Template Kind are follow-ups — see `Ezagent.Orchestrator.OrchestratorRecipe`.
  """

  require Logger

  alias Ezagent.SkillRegistry
  alias Ezagent.Orchestrator.OrchestratorRecipe

  @compile_env Mix.env()
  @orchestrator_skill_ref "ezagent-session-orchestrator"
  @skills_relroot ".claude/skills"
  @orchestrator_skill_marker_relpath "SKILL.md"
  @orchestrator_hint_line "## Use the ezagent-session-orchestrator skill for all session coordination work."

  @doc """
  Install the template's role into `config_dir` (T2 — generalized over the
  agent's actual role, not hardcoded to `orchestrator`).

  Reads the role NAME from the template's `"role"` field (`role_name/1`): an
  absent / `"default"` role is a `:ok` no-op (legacy cc agents). Any named role
  (`orchestrator`, `pm`, `dev-together`, …) composes its recipe (`resolve_role/1`)
  → resolves + copies its skills + appends the cc skill-load hint. A `nil`
  config_dir is also a no-op. Returns `{:error, _}` on a recipe / copy /
  source-resolution failure (see `try_apply/3` for the best-effort wrapper).
  """
  @spec bootstrap(map(), String.t() | nil) :: :ok | {:error, term()}
  def bootstrap(_tmpl, nil), do: :ok

  def bootstrap(tmpl, config_dir) when is_map(tmpl) and is_binary(config_dir) do
    case role_name(tmpl) do
      nil ->
        :ok

      name ->
        with {:ok, sandbox_content} <- resolve_role(name),
             :ok <- install_role_sandbox(sandbox_content, config_dir) do
          :ok
        end
    end
  end

  @doc """
  Compose the named role's recipe into its `sandbox_content`
  (`%{skills, plugins, prompt}`) via the unified `roles/0` + `Ezagent.Agent.Recipe.Compose`
  path (RF-9). Role-agnostic (T2): the SAME path serves `orchestrator`, `pm`,
  `dev-together`, or any other registered cc role.

  The recipe is looked up BY NAME in `Ezagent.Agent.RecipeRegistry` (built-ins are
  seeded at plugin boot from `roles/0`) — NOT re-derived from a bespoke compose.
  This routes the role through the SAME registry indirection RF-5a uses, and is
  the documented re-point seam for the future persisted
  `template://system/recipe/<name>` Template (swap the lookup source without
  touching the installer).

  Fails closed as `{:error, {:role_unresolved, {:role_not_registered, name}}}` —
  the registry has no such role. For a built-in this is a real boot-order /
  wiring bug: `roles/0` runs in boot Phase 2, long before any agent spawn, so it
  MUST be present at spawn time. We do NOT fall back to a bespoke compose to mask
  an empty registry (let-it-crash) — `try_apply/3` surfaces it as a degraded
  spawn + telemetry, exactly as a missing skill source does.

  The cc flavor declares no per-instance behaviors, so the role's are composed
  alone (`flavor_behaviors: []`).
  """
  @spec resolve_role(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_role(name) when is_binary(name) do
    case Ezagent.Agent.RecipeRegistry.lookup(name) do
      {:ok, %Ezagent.Agent.Recipe{} = role} ->
        %{sandbox_content: sandbox_content} =
          Ezagent.Agent.Recipe.Compose.materialize(role, %{flavor_behaviors: []})

        {:ok, sandbox_content}

      :error ->
        {:error, {:role_unresolved, {:role_not_registered, name}}}
    end
  end

  @doc """
  Back-compat alias for the orchestrator role — `resolve_role(OrchestratorRecipe.name())`.
  Kept so existing callers/tests that resolve the orchestrator specifically keep
  working; new code passes the agent's actual role name to `resolve_role/1`.
  """
  @spec resolve_orchestrator_recipe() :: {:ok, map()} | {:error, term()}
  def resolve_orchestrator_recipe, do: resolve_role(OrchestratorRecipe.name())

  @doc """
  Install a composed role `sandbox_content` into `config_dir` — PURE filesystem.

  Consumes the full `%{skills, plugins, prompt}` contract:

  - `skills` — for each ref: resolve its source dir + copy it into
    `config_dir/skills/<ref>` (idempotent — an existing dir is left untouched).
  - the cc skill-load **hint** is appended to `CLAUDE.md` only when the
    `ezagent-session-orchestrator` skill is among the installed skills — the
    hint is derived from the resolved skills, NOT hardcoded, so an empty or
    different skills list leaves no stale orchestrator hint.
  - `plugins` — **fail-closed**: a non-empty list returns
    `{:error, {:unsupported_role_content, :plugins}}`. Plugin install is a PR-2
    deferral; a silent drop would be fail-open. (The orchestrator recipe has no
    plugins, so this never fires today; it guards a future role.)
  - `prompt` — intentionally NOT written here: the role persona rides the
    orchestrator's seed sandbox `CLAUDE.md`, which `Ezagent.Credential.HomeRuntime`
    copies into each per-agent `config_dir`; writing it here would duplicate it.

  Returns `{:error, _}` on the first skill that cannot be resolved/copied, or on
  unsupported role content.
  """
  @spec install_role_sandbox(map(), String.t()) :: :ok | {:error, term()}
  def install_role_sandbox(%{skills: skills} = sandbox_content, config_dir)
      when is_list(skills) and is_binary(config_dir) do
    with :ok <- reject_unsupported_content(sandbox_content),
         :ok <- install_skills(skills, config_dir),
         :ok <- maybe_append_orchestrator_hint(skills, config_dir) do
      :ok
    end
  end

  # PR-2 installs sandbox CONTENT = skills only. A role that carries plugins
  # (a future capability) must fail closed rather than be silently dropped —
  # `try_apply/3` then surfaces degraded meta + telemetry.
  defp reject_unsupported_content(%{plugins: plugins}) when is_list(plugins) and plugins != [],
    do: {:error, {:unsupported_role_content, :plugins}}

  defp reject_unsupported_content(_), do: :ok

  # The hint is derived from the installed skills, not hardcoded: only append it
  # when the orchestrator skill is actually present.
  defp maybe_append_orchestrator_hint(skills, config_dir) do
    if @orchestrator_skill_ref in skills do
      append_orchestrator_claude_md_hint(config_dir)
    else
      :ok
    end
  end

  @doc """
  Best-effort wrapper around `bootstrap/2` for the spawn path: it NEVER fails the
  spawn. On success returns `{:ok, %{}}`; on a bootstrap error it logs a warning,
  emits `[:ezagent, :cc, :role_bootstrap, :failed]` telemetry, and returns
  `{:ok, %{role_degraded: true, role_degraded_reason: reason}}` so the agent spawns
  as a plain cc agent and the caller can surface the degraded status to the owner
  (SPEC 2026-05-26 Gap B). A failure to compose the role recipe is treated
  identically to a missing skill source — the spawn degrades, never crashes.
  """
  @spec try_apply(map(), String.t() | nil, URI.t()) :: {:ok, map()}
  def try_apply(tmpl, config_dir, %URI{} = agent_uri) do
    case bootstrap(tmpl, config_dir) do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: role-bootstrap failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)} — " <>
            "the agent will spawn as a plain cc agent (best-effort UX, " <>
            "SPEC 2026-05-26-session-create-orchestrator-unified Gap B); " <>
            "caller MUST surface the degraded status to the owner."
        )

        :telemetry.execute(
          [:ezagent, :cc, :role_bootstrap, :failed],
          %{count: 1},
          %{agent_uri: agent_uri, reason: reason, config_dir: config_dir}
        )

        {:ok, %{role_degraded: true, role_degraded_reason: reason}}
    end
  end

  @doc "Whether a template map declares the `orchestrator` role (`\"role\" => \"orchestrator\"`/`:orchestrator`). Retained for callers that branch specifically on the orchestrator; `bootstrap/2` itself now gates on the generic `role_name/1`. Anything else is `false`."
  @spec orchestrator_recipe?(map()) :: boolean()
  def orchestrator_recipe?(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "role") do
      "orchestrator" -> true
      :orchestrator -> true
      _ -> false
    end
  end

  def orchestrator_recipe?(_), do: false

  @doc """
  The role NAME a template declares, or `nil` when there is no role to install
  (the T2 gate that decides whether `bootstrap/2` installs anything).

  Reads the `"role"` field accepting both the canonical string form and the atom
  ingress form (`check_role/1` in `CcAgent` accepts either). An absent / empty /
  `"default"` role yields `nil` (no-op — every legacy cc agent). Any other name
  (`"orchestrator"`, `"pm"`, `"dev-together"`, …) is returned as a string for the
  `RoleRegistry` lookup.
  """
  @spec role_name(map()) :: String.t() | nil
  def role_name(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "role") do
      r when r in [nil, "", "default", :default] -> nil
      r when is_binary(r) -> r
      r when is_atom(r) -> Atom.to_string(r)
      _ -> nil
    end
  end

  def role_name(_), do: nil

  @doc "Locate the orchestrator skill source dir: the `:ezagent_plugin_cc, :orchestrator_skill_source` config override if set + present, else `Ezagent.SkillRegistry.resolve/1`. In dev only, a registry miss falls back to the old repo walk-up. `{:error, _}` if neither resolves. Equivalent to `resolve_skill_source/1` for the orchestrator skill ref."
  @spec resolve_orchestrator_skill_source() :: {:ok, String.t()} | {:error, term()}
  def resolve_orchestrator_skill_source, do: resolve_skill_source(@orchestrator_skill_ref)

  @doc "Locate a skill `ref`'s source dir: config overrides are honored as test seams; otherwise the generic `Ezagent.SkillRegistry` resolves the release-bundled source. In dev only, a registry miss falls back to walking up from the plugin `priv` dir for `.claude/skills/<ref>/SKILL.md`. `{:error, _}` if neither resolves."
  @spec resolve_skill_source(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_skill_source(ref) when is_binary(ref) do
    override = skill_source_override(ref)

    cond do
      is_binary(override) and override != "" ->
        if File.dir?(override),
          do: {:ok, override},
          else: {:error, {:skill_source_missing, override}}

      true ->
        resolve_skill_source_from_registry(ref)
    end
  end

  @doc "Walk UP the directory tree from `start_dir` looking for the orchestrator skill's `.claude/skills/ezagent-session-orchestrator/SKILL.md` marker; returns the skill dir or `{:error, {:skill_source_not_found, attempted_paths}}`."
  @spec search_orchestrator_skill_source_from(String.t()) ::
          {:ok, String.t()} | {:error, {:skill_source_not_found, [String.t()]}}
  def search_orchestrator_skill_source_from(start_dir) when is_binary(start_dir) do
    walk_for_skill(start_dir, @orchestrator_skill_ref, [])
  end

  @doc "The CLAUDE.md hint line `bootstrap/2` appends for orchestrator agents (directs the agent to the ezagent-session-orchestrator skill). Exposed so callers/tests can assert on it."
  @spec hint_line() :: String.t()
  def hint_line, do: @orchestrator_hint_line

  # Skill source is overridable per deployment (and per test). The orchestrator
  # skill keeps its dedicated single-ref override for back-compat; ANY ref (incl.
  # the orchestrator) may also be pointed at a source via the generic
  # `:role_skill_sources` map (ref => abs-path). Absent an override, a ref
  # resolves purely by the walk-upward search.
  defp skill_source_override(@orchestrator_skill_ref) do
    Application.get_env(:ezagent_plugin_cc, :orchestrator_skill_source) ||
      generic_skill_source_override(@orchestrator_skill_ref)
  end

  defp skill_source_override(ref), do: generic_skill_source_override(ref)

  defp generic_skill_source_override(ref) do
    case Application.get_env(:ezagent_plugin_cc, :role_skill_sources) do
      %{} = map -> Map.get(map, ref)
      _ -> nil
    end
  end

  defp resolve_skill_source_from_registry(ref) do
    case SkillRegistry.resolve(ref) do
      {:ok, {source_dir, _hash}} ->
        {:ok, source_dir}

      {:error, {:skill_source_not_found, ^ref}} = error ->
        if @compile_env == :dev, do: search_skill_source(ref), else: error
    end
  end

  defp search_skill_source(ref) do
    case :code.priv_dir(:ezagent_plugin_cc) do
      priv when is_list(priv) ->
        priv
        |> to_string()
        |> Path.expand()
        |> then(&walk_for_skill(&1, ref, []))

      _ ->
        {:error, {:skill_source_not_found, []}}
    end
  end

  defp walk_for_skill(dir, ref, attempted) do
    candidate = Path.join([dir, @skills_relroot, ref])
    marker = Path.join(candidate, @orchestrator_skill_marker_relpath)
    attempted = [candidate | attempted]

    cond do
      File.regular?(marker) ->
        {:ok, candidate}

      Path.dirname(dir) == dir ->
        {:error, {:skill_source_not_found, Enum.reverse(attempted)}}

      true ->
        walk_for_skill(Path.dirname(dir), ref, attempted)
    end
  end

  defp install_skills(skills, config_dir) do
    Enum.reduce_while(skills, :ok, fn ref, :ok ->
      with {:ok, source} <- resolve_skill_source(ref),
           :ok <- copy_skill(ref, source, config_dir) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp copy_skill(ref, source_dir, config_dir) do
    skills_root = Path.join(config_dir, "skills")
    dest_dir = Path.join(skills_root, ref)

    cond do
      File.dir?(dest_dir) ->
        :ok

      true ->
        with :ok <- File.mkdir_p(skills_root),
             {:ok, _} <- File.cp_r(source_dir, dest_dir) do
          :ok
        else
          {:error, reason} -> {:error, {:skill_copy_failed, reason}}
          err -> {:error, {:skill_copy_failed, err}}
        end
    end
  end

  defp append_orchestrator_claude_md_hint(config_dir) do
    claude_md = Path.join(config_dir, "CLAUDE.md")

    existing =
      case File.read(claude_md) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
        {:error, reason} -> {:error, reason}
      end

    case existing do
      {:error, reason} ->
        {:error, {:claude_md_hint_failed, reason}}

      content when is_binary(content) ->
        write_orchestrator_hint_if_missing(claude_md, content)
    end
  end

  defp write_orchestrator_hint_if_missing(claude_md, content) do
    if String.contains?(content, @orchestrator_hint_line) do
      :ok
    else
      new_content =
        if content == "" or String.ends_with?(content, "\n") do
          content <> @orchestrator_hint_line <> "\n"
        else
          content <> "\n" <> @orchestrator_hint_line <> "\n"
        end

      case File.write(claude_md, new_content) do
        :ok -> :ok
        {:error, reason} -> {:error, {:claude_md_hint_failed, reason}}
      end
    end
  end
end
