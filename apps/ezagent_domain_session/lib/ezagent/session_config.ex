defmodule Ezagent.Session.Config do
  @moduledoc "Single executable boundary for Session-Config operations."

  alias Ezagent.Session.Config.{Admission, Catalog, Executor, Operation, Readiness, Validation}

  @spec operation(String.t() | atom()) :: Operation.t() | nil
  @doc "Return the canonical descriptor for a Session-Config operation."
  def operation(name) when is_binary(name), do: Catalog.operation(name)

  def operation(name) when is_atom(name) do
    Enum.find(Catalog.operations(), &(&1.name == Atom.to_string(name)))
  end

  def operation(_), do: nil

  @spec execute(String.t() | atom(), map(), URI.t(), URI.t() | nil) :: term()
  @doc "Validate and execute one operation for an authenticated principal and addressed target."
  def execute(operation_name, args, %URI{} = principal, addressed_target) when is_map(args) do
    with %Operation{} = operation <- operation(operation_name),
         {:ok, target} <- normalize_target(operation, principal, addressed_target),
         {:ok, args} <- Validation.coerce(operation, args),
         :ok <- validate_target(operation, target),
         :ok <- Readiness.check(operation, target),
         {:ok, opts} <- derive_context(operation, principal, target),
         :ok <- Admission.check(operation, args, opts) do
      Executor.execute(operation.execute, args, opts)
    else
      nil -> {:error, {:unknown_operation, wire_name(operation_name)}}
      {:error, _} = error -> error
    end
  end

  def execute(_operation, _args, _principal, _target), do: {:error, :invalid_execution_context}

  defp normalize_target(%Operation{target_scope: :workspace}, principal, nil) do
    {:ok, Ezagent.Capability.workspace_of(principal)}
  rescue
    _ -> {:error, {:invalid_addressed_target, nil}}
  end

  defp normalize_target(%Operation{}, _principal, %URI{} = target), do: {:ok, target}

  defp normalize_target(%Operation{}, _principal, target),
    do: {:error, {:invalid_addressed_target, target}}

  defp validate_target(%Operation{target_scope: :session}, %URI{scheme: "session"}), do: :ok

  defp validate_target(%Operation{target_scope: :workspace}, %URI{scheme: "workspace"}), do: :ok

  defp validate_target(%Operation{target_scope: scope}, target) do
    {:error, {:invalid_addressed_target, scope, target}}
  end

  defp derive_context(%Operation{target_scope: :session}, principal, session_uri) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    working_copy = Ezagent.Entity.Session.read_template_working_copy(session_uri)

    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} ->
        {:ok,
         context_opts(
           principal,
           session_uri,
           workspace_uri,
           owner,
           Map.get(working_copy, :session_template_uri)
         )}

      {:ok, nil} ->
        {:error, {:context_derivation_failed, :owner}}

      {:error, reason} ->
        {:error, {:context_derivation_failed, :owner, reason}}
    end
  end

  defp derive_context(%Operation{target_scope: :workspace}, principal, workspace_uri) do
    {:ok, context_opts(principal, nil, workspace_uri, principal, nil)}
  end

  defp context_opts(principal, session_uri, workspace_uri, owner, parent_template_uri) do
    [
      caller: principal,
      caps: principal_caps(principal),
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner: owner,
      parent_template_uri: parent_template_uri
    ]
  end

  defp principal_caps(principal) do
    principal |> Ezagent.EntityCaps.load() |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  defp wire_name(name) when is_atom(name), do: Atom.to_string(name)
  defp wire_name(name), do: name
end
