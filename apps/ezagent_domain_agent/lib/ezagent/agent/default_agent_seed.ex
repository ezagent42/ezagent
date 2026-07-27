defmodule Ezagent.Agent.DefaultAgentSeed do
  @moduledoc """
  Phase 3 ③ T7a — the GENERIC mechanism for **template-seeding a default
  role-agent**: write a `cc × <role>` AgentTemplate (role baked into the
  `:template` content). It is boot-safe and runs from each plugin's `after_boot/0`.

  This is a generic template-seed engine reused by any role-owning caller's boot
  seed and by the generic by-role materialize path. It carries NO product-recipe
  knowledge
  of its own — callers pass the role name + content; this engine only writes the
  `cc × <role>` template. It lives in `ezagent_domain_agent` (NOT forked
  per-plugin) because it COMPOSES
  domain.agent primitives callers would otherwise byte-duplicate — the FF-1
  `cross_file_duplicate_fn_groups` arch gate forbids that fork accretion. It
  introduces NO new mechanism: it only wires
  `Ezagent.LocalRuntime.ensure_started_detailed/1` + `Ezagent.ActionSet.Template`
  `:write` (the same play `Ezagent.Orchestrator.CcOrchestratorSeed` uses).

  ## Grant lives in a mix task, NOT here (p7)

  The recipe-cap GRANT (admin-authority cap granting, under the admin entity)
  is NOT done at boot — that would fire the grant from a non-deliberate after_boot
  entry, which the `cap_check_only_at_chokepoint` p7 probe forbids. It moved to
  the sanctioned operator/materialize mix task
  `Mix.Tasks.Ezagent.Agent.GrantRecipeCaps` (a deliberate grant entry). At boot
  the default agent isn't live anyway. Socialware materialization now issues the
  caps into its durable recipe binding before spawn, and the agent self-stores
  them in `create/1`; the mix task remains an explicit operator hand-off, not a
  materializer callback.

  ## Flavor `cc` (2026-06-28 decision)

  `cc` (`Ezagent.PluginCc.Template.CcAgent`) is the ONLY flavor that wires BOTH
  role hooks a default agent needs: `check_role/1` (validates a non-builtin role
  against `Ezagent.Agent.RecipeRegistry`, T4) AND `OrchestratorBootstrap.try_apply/3`
  (installs the role's `skills` into the per-agent `config_dir`, T2). `cc-headless`
  wires neither. `role: "<name>"` baked into the content threads through
  `Ezagent.Entity.AgentTemplate.to_template_data/2` → cc data `"role"` → both hooks
  at instantiate. The orchestrator seed is also `cc`.

  ## T7a = MECHANISM only

  `cc` skips RF-5a `CapMint` (file-flavor → RF-5b deferred), so the cap grant is
  EXPLICIT (admin least-priv) — done by the `GrantRecipeCaps` mix task, not here.
  The LIVE `cc` spawn (real `claude` sidecar + per-agent `config_dir` + the grant
  LANDING on a live identity slice) is the T7b agent-browser e2e proof — this
  module never spawns a live agent and never grants.

  ## Spec map

  Callers pass a `t:spec/0`:

      %{
        role_name: "pm-coordinator",        # the registered role (T4/T5)
        description: "...",                  # AgentTemplate content description
        recipe: %{requested_caps: [...]},   # the role recipe (caps to grant)
        project_cwd: "/abs/dir",             # required cwd for the cc template
        telemetry_prefix: [:ezagent, :my_plugin, :role_seed]
      }
  """

  require Logger

  @flavor "cc"

  @typedoc "The default-agent seed spec (see the moduledoc)."
  @type spec :: %{
          required(:role_name) => String.t(),
          required(:description) => String.t(),
          required(:recipe) => map(),
          required(:project_cwd) => String.t(),
          required(:telemetry_prefix) => [atom()]
        }

  @doc """
  Seed the `cc × <role>` AgentTemplate (template-seed ONLY). Idempotent +
  boot-safe: a template-write failure downgrades to a warning + telemetry (an
  `after_boot` MUST NOT crash a boot).

  The recipe-cap GRANT is no longer done here — it moved to the sanctioned
  operator mix task `Mix.Tasks.Ezagent.Agent.GrantRecipeCaps` (p7: issue/store is
  a deliberate entry, not a boot-time auto-grant). The normal materialize lane
  uses the durable recipe binding + `create/1` self-store instead.
  """
  @spec seed(spec()) :: :ok
  def seed(%{role_name: role, telemetry_prefix: prefix} = spec) do
    case seed_template(role, template_content(role, spec.description, spec.project_cwd)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{role} seed: template write failed: #{inspect(reason)} — the #{role} " <>
            "default agent will use an unpopulated template until re-seeded (boot-safe)"
        )

        :telemetry.execute(prefix ++ [:failed], %{count: 1}, %{reason: reason})
        :ok
    end
  end

  @doc "The `cc` AgentTemplate URI string for `role` (`template://system/agent/<role>`)."
  @spec template_uri(String.t()) :: String.t()
  def template_uri(role) when is_binary(role), do: template_uri_struct(role) |> URI.to_string()

  @doc "The default agent ENTITY URI for `role` (`entity://system/agent/<role>`) — the grant target + the URI a T7b live spawn materializes."
  @spec agent_uri(String.t()) :: URI.t()
  def agent_uri(role) when is_binary(role), do: Ezagent.URI.agent(:system, role)

  @doc """
  The default per-agent `project_cwd` for a role-agent (`~/.ezagent/<role>`, or
  `<tmp>/.ezagent/<role>` when there is no home dir).

  This is the generic default a role-agent uses absent a per-role `*_cwd` value
  DECLARED in its registered recipe (`config[:project_cwd]`) — lifted here so the
  generic by-role materialize path can build a role-agent's template content
  WITHOUT a compile dep on the role-owning plugin.
  """
  @spec default_project_cwd(String.t()) :: String.t()
  def default_project_cwd(role) when is_binary(role) do
    Path.join([System.user_home() || System.tmp_dir!(), ".ezagent", role])
  end

  @doc """
  The `cc × <role>` AgentTemplate `:template` slice CONTENT. `flavor: "cc"` +
  `role: role` baked in (both thread through `AgentTemplate.to_template_data/2`).
  """
  @spec template_content(String.t(), String.t(), String.t()) :: map()
  def template_content(role, description, project_cwd)
      when is_binary(role) and is_binary(description) and is_binary(project_cwd) do
    %{
      name: role,
      description: description,
      flavor: @flavor,
      project_cwd: project_cwd,
      config_dir: nil,
      role: role,
      default_caps: [],
      created_by: nil,
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Write the `role`'s AgentTemplate `:template` slice from `content`. Idempotent
  (`:write` is a mutable replace on the versionless URI). Mirrors
  `CcOrchestratorSeed.write_template_slice/2`.
  """
  @spec seed_template(String.t(), map()) :: :ok | {:error, term()}
  def seed_template(role, content) when is_binary(role) and is_map(content) do
    uri = template_uri_struct(role)

    with {:ok, _pid} <- ensure_kind(uri) do
      write_template_slice(uri, content)
    end
  end

  # --- internals ---------------------------------------------------------

  defp template_uri_struct(role), do: Ezagent.URI.template(:system, :agent, role)

  defp ensure_kind(%URI{} = uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(uri) do
      {:ok, _started_or_already, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  # Dispatch `Ezagent.ActionSet.Template` `:write` under the admin entity with a
  # target-issued narrow `template.write` artifact.
  defp write_template_slice(%URI{} = uri, content) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.write")
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <-
           Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
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
           }) do
        {:ok, %{content: _}} -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_template_write_result, other}}
      end
    end
  end
end
