defmodule EzagentPluginHello.Template.HelloSession do
  @moduledoc """
  `session.hello` Template Class (Phase 2 — the "factory" seam).

  Makes a hello app **creatable through the substrate's generic Tier-3 session
  create path** — the same path world's internal console uses (`session.create`
  → the registered Template Class's `instantiate/3`). World needs NO edit: it
  creates any registered session type generically; declaring this class (via the
  plugin's `template_classes/0`) is what lets the internal reader spin up a hello app.

  `instantiate/3` delegates to `EzagentPluginHello.App.ensure_app/2` — the same
  in-code flow Phase 0/1 already use (a `public_view` SessionTemplate + a live
  socialware Session + a joined `HelloBuilder` member) — so there is exactly ONE
  place that knows how to stand up a hello app.
  """

  @behaviour Ezagent.Kind.Template

  alias Ezagent.LocalRuntime
  alias EzagentPluginHello.{App, ReusableLlmAgent}

  @impl Ezagent.Kind.Template
  def template_name, do: "session.hello"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_session_name(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(tmpl_name, tmpl, workspace_uri) do
    do_instantiate(tmpl_name, tmpl, workspace_uri, nil)
  end

  @impl Ezagent.Kind.Template
  def instantiate(tmpl_name, tmpl, workspace_uri, opts) do
    do_instantiate(tmpl_name, tmpl, workspace_uri, Keyword.get(opts, :caller))
  end

  # hello-A — `caller` is the create-session dispatch caller (threaded by
  # `Behavior.Workspace.create_session_via_class` when it is available). The
  # caller becomes the session OWNER, so any user creating a hello session in
  # their own workspace owns it ("the caller becomes the session owner",
  # `Behavior.Workspace` :create_session). Nil (direct/boot callers) falls back
  # to `App.create_app/3`'s default.
  defp do_instantiate(
         _tmpl_name,
         %{"session_name" => session_name} = tmpl,
         %URI{} = workspace_uri,
         caller
       )
       when is_binary(session_name) and session_name != "" do
    with :ok <- check_class(tmpl),
         {:ok, selection} <- reusable_llm_selection(tmpl),
         :ok <- preflight_reusable_llm(selection, caller, workspace_uri) do
      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
      session_uri = Ezagent.URI.session(workspace_name, :hello, session_name)
      fresh? = not LocalRuntime.kind_alive?(session_uri)

      # rev6 / #912 — `instantiate/3` runs INSIDE the `workspace.create_session`
      # dispatch, so it may create the session and its config but MUST NOT spawn
      # the declared team. `Workspace.create_session` fires the socialware-install
      # transaction once this returns. (`App.ensure_app/3` is the create+install
      # composite, for boot seeding and tests.)
      create_opts =
        if caller do
          [owner: caller] ++ llm_create_opts(tmpl, selection)
        else
          llm_create_opts(tmpl, selection)
        end

      case App.create_app(workspace_name, session_name, create_opts) do
        {:ok, ^session_uri} ->
          {:ok, [session_uri], %{fresh?: fresh?, vertical: :hello}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp do_instantiate(_tmpl_name, tmpl, _workspace_uri, _caller),
    do: {:error, {:invalid_template, tmpl}}

  defp reusable_llm_selection(tmpl) do
    flavor = Map.get(tmpl, "llm_flavor") || Map.get(tmpl, :llm_flavor)
    agent_uri = Map.get(tmpl, "llm_agent_uri") || Map.get(tmpl, :llm_agent_uri)

    case {flavor, agent_uri} do
      {flavor, agent_uri}
      when is_binary(flavor) and flavor != "" and not is_nil(agent_uri) ->
        with {:ok, parsed_uri} <- parse_agent_uri(agent_uri) do
          {:ok, %{flavor: flavor, agent_uri: parsed_uri}}
        end

      {_flavor, nil} ->
        {:error, :llm_agent_required}

      {nil, _agent_uri} ->
        {:error, {:invalid_reusable_llm_selection, :missing_llm_flavor}}

      {_flavor, _agent_uri} ->
        {:error, {:invalid_reusable_llm_selection, :invalid_llm_flavor}}
    end
  end

  defp parse_agent_uri(%URI{} = agent_uri), do: {:ok, agent_uri}

  defp parse_agent_uri(agent_uri) when is_binary(agent_uri) do
    case Ezagent.URI.parse(agent_uri) do
      {:ok, %URI{} = parsed} -> {:ok, parsed}
      _ -> {:error, {:invalid_reusable_llm_agent_uri, agent_uri}}
    end
  end

  defp parse_agent_uri(agent_uri),
    do: {:error, {:invalid_reusable_llm_agent_uri, agent_uri}}

  defp preflight_reusable_llm(_selection, nil, _workspace_uri),
    do: {:error, {:invalid_reusable_llm_agent, :unauthorized}}

  defp preflight_reusable_llm(
         %{flavor: flavor, agent_uri: agent_uri},
         caller,
         workspace_uri
       ) do
    case ReusableLlmAgent.validate(caller, workspace_uri, flavor, agent_uri) do
      {:ok, _candidate} -> :ok
      {:error, reason} -> {:error, {:invalid_reusable_llm_agent, reason}}
    end
  end

  defp llm_create_opts(_tmpl, %{flavor: flavor, agent_uri: agent_uri}),
    do: [llm_flavor: flavor, llm_agent_uri: agent_uri]

  defp check_class(%{"class" => "session.hello"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_session_name(%{"session_name" => name}) when is_binary(name) and name != "", do: :ok
  defp check_session_name(_), do: {:error, :missing_session_name}
end
