defmodule Ezagent.Session.Config.Admission do
  @moduledoc false

  alias Ezagent.Session.Config.Operation

  @spec check(Operation.t(), map(), keyword()) ::
          :ok | {:error, {:gate_failed, atom(), term()}}
  @doc false
  def check(%Operation{admission_gate: :session_membership}, _args, opts) do
    session_uri = Keyword.fetch!(opts, :session_uri)
    principal = Keyword.fetch!(opts, :caller)

    case Ezagent.Session.Membership.authorize(session_slice(session_uri), principal, session_uri) do
      :ok -> :ok
      {:error, reason} -> gate_error(:session_membership, reason)
    end
  end

  def check(%Operation{admission_gate: :workspace_caps}, _args, opts) do
    caps = Keyword.fetch!(opts, :caps)
    workspace_uri = Keyword.fetch!(opts, :workspace_uri)
    caller = Keyword.fetch!(opts, :caller)

    if template_cap?(caps, :agent_template, workspace_uri, caller) or
         template_cap?(caps, :session_template, workspace_uri, caller) do
      :ok
    else
      gate_error(:workspace_caps, :unauthorized)
    end
  end

  def check(%Operation{admission_gate: :template_write}, _args, opts) do
    caps = Keyword.fetch!(opts, :caps)
    workspace_uri = Keyword.fetch!(opts, :workspace_uri)
    caller = Keyword.fetch!(opts, :caller)

    if template_write_cap?(caps, workspace_uri, caller),
      do: :ok,
      else: gate_error(:template_write, :unauthorized)
  end

  def check(
        %Operation{
          admission_gate: :operation_caps,
          execute:
            {:agent_action,
             %{
               agent_arg: agent_arg,
               behavior: behavior,
               cap_behavior: cap_behavior,
               action: action
             }}
        },
        args,
        opts
      ) do
    with agent_name when is_binary(agent_name) and agent_name != "" <- Map.get(args, agent_arg),
         workspace_uri <- Keyword.fetch!(opts, :workspace_uri),
         workspace_name <- Ezagent.URI.workspace_name!(workspace_uri),
         agent_uri <- Ezagent.URI.agent(workspace_name, agent_name),
         _target <- Ezagent.URI.with_action(agent_uri, behavior, action),
         needed <- %{
           kind: Ezagent.Entity.Agent.type_name(),
           behavior: cap_behavior,
           action: action,
           instance: agent_uri,
           workspace_uri: workspace_uri
         },
         true <-
           Ezagent.Capability.Authorization.authorizes?(Keyword.fetch!(opts, :caps), needed) do
      :ok
    else
      _ -> gate_error(:operation_caps, :unauthorized)
    end
  rescue
    _ -> gate_error(:operation_caps, :unauthorized)
  end

  @doc false
  @spec template_cap?(MapSet.t() | list(), :agent_template | :session_template, URI.t(), URI.t()) ::
          boolean()
  def template_cap?(caps, kind, %URI{} = workspace_uri, %URI{} = caller) do
    action =
      case kind do
        :agent_template -> :list_agent_templates
        :session_template -> :list_session_templates
      end

    workspace_action_authorized?(caps, workspace_uri, caller, action)
  end

  @doc false
  def template_write_cap?(caps, %URI{} = workspace_uri, %URI{} = caller) do
    workspace_action_authorized?(caps, workspace_uri, caller, :write_session_templates)
  end

  defp workspace_action_authorized?(caps, workspace_uri, caller, action) do
    target = Ezagent.URI.with_action(workspace_uri, :workspace, action)

    result =
      Ezagent.Invocation.with_admin_operator(caller, fn ->
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{},
          ctx: %{
            caller: caller,
            caps: operator_dispatch_caps(caller, caps),
            reply: {:caller_inbox, self()}
          },
          origin: :trusted_internal
        })
      end)

    case result do
      {:ok, _result} -> true
      :ok -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp operator_dispatch_caps(%URI{} = caller, caps) do
    if Ezagent.URI.stable_key(caller) ==
         Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin)) do
      MapSet.new()
    else
      MapSet.new(caps)
    end
  end

  defp session_slice(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, slice} when is_map(slice) -> slice
      _ -> nil
    end
  end

  defp gate_error(gate, reason), do: {:error, {:gate_failed, gate, reason}}
end
