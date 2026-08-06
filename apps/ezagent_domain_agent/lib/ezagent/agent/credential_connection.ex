defmodule Ezagent.Agent.CredentialConnection do
  @moduledoc """
  Normalizes a flavor's declarative credential connection requirement.

  Connection requirements belong to the registered Template Class so the
  credential admission flow remains flavor-neutral. A flavor without an
  explicit declaration does not require credentials.
  """

  alias Ezagent.AgentFlavorRegistry

  @type descriptor ::
          :not_required
          | {:pty, %{label: String.t()}}
          | {:api_key, %{provider: String.t(), label: String.t()}}

  @doc """
  Returns the normalized credential connection requirement for `flavor`.

  Only the flavor's registered Template Class may declare a connection. An
  unknown flavor or malformed declaration is unsupported rather than falling
  back to a core-defined connection.
  """
  @spec for_flavor(String.t(), keyword()) :: {:ok, descriptor()} | {:error, term()}
  def for_flavor(flavor, opts \\ []) when is_binary(flavor) and is_list(opts) do
    case AgentFlavorRegistry.template_class_for(flavor) do
      {:ok, template_class} -> template_connection(template_class, opts)
      {:error, _reason} -> {:error, :unsupported_connection}
    end
  end

  defp template_connection(template_class, opts) do
    case Code.ensure_loaded(template_class) do
      {:module, ^template_class} ->
        template_class
        |> raw_connection(opts)
        |> normalize()

      {:error, _reason} ->
        {:error, :unsupported_connection}
    end
  end

  defp raw_connection(template_class, opts) do
    if function_exported?(template_class, :credential_connection, 1) do
      template_class.credential_connection(opts)
    else
      :not_required
    end
  end

  defp normalize(:not_required), do: {:ok, :not_required}

  defp normalize({:pty, label}) when is_binary(label) and label != "",
    do: {:ok, {:pty, %{label: label}}}

  defp normalize({:api_key, provider, label})
       when is_binary(provider) and provider != "" and is_binary(label) and label != "",
       do: {:ok, {:api_key, %{provider: provider, label: label}}}

  defp normalize(_declaration), do: {:error, :unsupported_connection}
end
