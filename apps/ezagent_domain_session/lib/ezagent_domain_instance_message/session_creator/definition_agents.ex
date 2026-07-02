defmodule EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents do
  @moduledoc """
  T2-1b — materialize a socialware `Definition`'s `agents`
  (`[%{recipe: name, role_name: name}]`) into a live session as SPAWNED MEMBERS.

  `agents` is the socialware-side declaration "these are the agents this
  socialware brings into the session"; materialization turns each into a live,
  session/workspace-scoped agent that is JOINED as a session member with its
  `role_name` facet (so `{:role, name}` routing rules resolve to it) and holds
  its recipe's `requested_caps`.

  Per agent, the pipeline REUSES the existing safe managed-member envelope shape
  (`Ezagent.Orchestrator.Tools.add_managed_member`: preflight → spawn → faceted
  `session.join` → cleanup-on-join-failure) so a join failure never leaves an
  orphan worker:

    1. **role_name uniqueness FIRST** — reject a `role_name` that collides with
       an existing member (that is NOT this agent's own deterministic URI) OR
       another entry in the same `agents` batch, BEFORE spawning (no wasted live
       agent). An existing member at this agent's own deterministic URI is an
       idempotent re-materialize (repair/restart) → skip.
    2. **resolve recipe by workspace** — `RecipeRegistry.lookup(workspace, name)`,
       fail-closed on `:error` (never a cap-less spawn; #1116).
    3. **spawn** — recipe → cc AgentTemplate content (`DefaultAgentSeed`) →
       `Agent.spawn_from_template_content` at the deterministic per-session URI.
    4. **join + cleanup** — faceted `session.join` carrying `%{role_name: name}`;
       on join `{:error, _}` terminate the worker we just spawned.
    5. **grant caps LAST** — `GrantRecipeCaps.grant_recipe_caps` grants the
       recipe's `requested_caps` (fail-closed, no partial). Runs after a
       successful join so join-failure cleanup only has to terminate.

  Authority is SYSTEM-MEDIATED materialization (mirrors
  `Materializer.join_session_members` / `TemplateTeam.ensure_member_present`):
  the spawn runs under the session owner (`granted_by`) with
  `list_caps_for_materialization/1`, and the join/cleanup dispatch under the
  genesis admin entity with an inline least-priv cap.

  > **Rebase note (T1, reconciled):** T1's structured `recipe:<name>` subject has
  > landed. `agents[].recipe` accepts EITHER a plain recipe name (`guide`) or the
  > structured subject (`recipe:guide`); `lookup_ref/1` strips a single leading
  > `recipe:` prefix so both resolve identically through `RecipeRegistry.lookup/2`
  > (which itself takes a plain name and re-derives the subject).
  """

  require Logger

  alias Ezagent.Agent.{DefaultAgentSeed, RecipeRegistry, SessionAgentMaterialize}
  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Invocation
  alias EzagentDomainInstanceMessage.SessionCreator
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :socialware, :definition_agents]
  @agent_description "socialware-declared agent materialized per-session (Definition.agents, T2-1b)"

  @doc """
  Materialize `agents` into `session_uri`. `granted_by` is the session owner
  (the #154-clean grant/spawn root). Idempotent on the repair/restart path.

  Returns `:ok` or `{:error, reason}` (fail-loud — a create-path failure rolls
  the session back).
  """
  @spec materialize_definition_agents(URI.t(), URI.t(), URI.t(), [map()]) ::
          :ok | {:error, term()}
  def materialize_definition_agents(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        agents
      )
      when is_list(agents) do
    agents
    |> Enum.reduce_while({:ok, MapSet.new()}, fn agent, {:ok, batch_seen} ->
      role_name = role_name_of(agent)

      cond do
        not valid_agent?(agent) ->
          {:halt, {:error, {:invalid_socialware_agent, agent}}}

        MapSet.member?(batch_seen, role_name) ->
          {:halt, {:error, {:duplicate_agent_role_name, role_name}}}

        true ->
          case materialize_one(session_uri, workspace_uri, granted_by, agent) do
            :ok -> {:cont, {:ok, MapSet.put(batch_seen, role_name)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = err -> err
    end
  end

  def materialize_definition_agents(_session, _ws, _granted_by, _agents), do: :ok

  defp materialize_one(session_uri, workspace_uri, granted_by, %{} = agent) do
    recipe_name = lookup_ref(recipe_of(agent))
    role_name = role_name_of(agent)
    planned_uri = planned_agent_uri(role_name, session_uri, workspace_uri)

    case existing_member_for_role(session_uri, role_name) do
      %URI{} = existing_uri ->
        if same_uri?(existing_uri, planned_uri) do
          # Idempotent re-materialize (repair/restart) — our agent already
          # joined at this role_name. Skip (do not re-spawn / re-grant).
          :ok
        else
          {:error, {:agent_role_name_conflict, role_name, existing_uri}}
        end

      nil ->
        with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
             :ok <-
               spawn_and_join(
                 session_uri,
                 workspace_uri,
                 granted_by,
                 planned_uri,
                 recipe,
                 recipe_name,
                 role_name
               ),
             :ok <- grant_recipe_caps(planned_uri, recipe) do
          :ok
        end
    end
  end

  # --- resolve --------------------------------------------------------------

  defp lookup_recipe(%URI{} = workspace_uri, recipe_name) do
    case RecipeRegistry.lookup(URI.to_string(workspace_uri), recipe_name) do
      {:ok, recipe} -> {:ok, recipe}
      :error -> {:error, {:unknown_agent_recipe, recipe_name}}
    end
  end

  # T1 rebase reconciliation: recipe subjects are the structured `recipe:<name>`
  # form (T1 project B). `RecipeRegistry.lookup/2` takes a PLAIN recipe name and
  # re-derives the `recipe:<name>` subject internally, and the same plain name is
  # reused as the AgentTemplate name — so normalize a single leading `recipe:`
  # prefix here so both a bare `guide` and a prefixed `recipe:guide` in
  # `agents[].recipe` resolve identically. Idempotent: strips at most one prefix.
  defp lookup_ref("recipe:" <> rest) when rest != "", do: rest
  defp lookup_ref(name), do: name

  # --- spawn + join ---------------------------------------------------------

  defp spawn_and_join(
         session_uri,
         workspace_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name
       ) do
    content =
      DefaultAgentSeed.template_content(
        recipe_name,
        @agent_description,
        recipe_project_cwd(recipe, recipe_name)
      )

    source_template_uri = Ezagent.URI.template(:system, :agent, recipe_name)

    case Ezagent.Entity.Agent.spawn_from_template_content(
           content,
           planned_uri,
           granted_by,
           workspace_uri,
           caller: granted_by,
           caps: SessionCreator.list_caps_for_materialization(granted_by),
           source_template_uri: source_template_uri
         ) do
      {:ok, %{}} ->
        join_or_cleanup(session_uri, planned_uri, role_name)

      {:error, reason} ->
        {:error, {:agent_spawn_failed, role_name, reason}}
    end
  end

  # Faceted `session.join` carrying the `%{role_name: name}` facet. On failure,
  # terminate the worker we just spawned (the add_managed_member cleanup
  # envelope) so a denied/failed join never leaves an orphan.
  defp join_or_cleanup(session_uri, %URI{} = member_uri, role_name) do
    case join_member(session_uri, member_uri, role_name) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = terminate_worker(member_uri)
        {:error, {:agent_join_failed, role_name, reason}}
    end
  end

  defp join_member(%URI{} = session_uri, %URI{} = member_uri, role_name) do
    _ = SessionCreator.demand_spawn_member(member_uri)
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    admin = Ezagent.Entity.User.admin_uri()

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri, role_name: role_name},
        ctx: %{
          caller: admin,
          caps: MapSet.new([join_cap(session_uri, admin)]),
          reply: {:caller_inbox, self()}
        }
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_join_result, other}}
    end
  end

  defp terminate_worker(%URI{} = member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(member_uri)}?action=sandbox.destroy")
    admin = Ezagent.Entity.User.admin_uri()

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          caps: MapSet.new([destroy_cap(member_uri, admin)]),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  # --- grant ----------------------------------------------------------------

  defp grant_recipe_caps(%URI{} = agent_uri, recipe) do
    case GrantRecipeCaps.grant_recipe_caps(agent_uri, recipe, @telemetry_prefix) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_grant_recipe_caps_failed, reason}}
    end
  end

  # --- inline caps (system-mediated materialization) ------------------------

  defp join_cap(%URI{} = session_uri, %URI{} = admin) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        :any,
        :join,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: admin,
        granted_at: DateTime.utc_now()
    }
  end

  defp destroy_cap(%URI{} = member_uri, %URI{} = admin) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :agent,
        :any,
        :destroy,
        Ezagent.URI.instance(member_uri),
        Ezagent.Capability.workspace_of(member_uri)
      )
      | granted_by: admin,
        granted_at: DateTime.utc_now()
    }
  end

  # --- helpers --------------------------------------------------------------

  @doc """
  The deterministic per-session agent URI for `role_name`
  (`entity://<workspace>/agent/<role_name>-<session-disc>`). Delegates to
  `SessionAgentMaterialize.planned_agent_uri/3` (the same session-discriminator
  shape) keyed on `role_name` (per-session unique) so two socialware agents
  sharing a recipe get distinct URIs.
  """
  @spec planned_agent_uri(String.t(), URI.t(), URI.t()) :: URI.t()
  defdelegate planned_agent_uri(role_name, session_uri, workspace_uri),
    to: SessionAgentMaterialize

  defp existing_member_for_role(%URI{} = session_uri, role_name) do
    Members.role_name_to_uri(read_members(session_uri), role_name)
  end

  defp read_members(%URI{} = session_uri) do
    slice_module = Ezagent.ActionSet.Session.state_slice()

    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(slice_module, %{})

        Map.get(Map.get(chat_slice, :state, chat_slice), :members, %{})

      :error ->
        %{}
    end
  end

  # The per-agent `project_cwd` the recipe DECLARES (atom/string-key tolerant),
  # else the generic sandbox default. Inlined (no shared `config_get`) so the
  # body stays distinct from `SessionAgentMaterialize`'s by-role variant.
  defp recipe_project_cwd(recipe, role) do
    config = Map.get(recipe, :config) || Map.get(recipe, "config") || %{}

    case Map.get(config, :project_cwd) || Map.get(config, "project_cwd") do
      cwd when is_binary(cwd) -> cwd
      _ -> DefaultAgentSeed.default_project_cwd(role)
    end
  end

  defp valid_agent?(%{} = agent),
    do: is_binary(recipe_of(agent)) and is_binary(role_name_of(agent))

  defp valid_agent?(_), do: false

  defp recipe_of(agent), do: Map.get(agent, :recipe) || Map.get(agent, "recipe")
  defp role_name_of(agent), do: Map.get(agent, :role_name) || Map.get(agent, "role_name")

  defp same_uri?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
end
