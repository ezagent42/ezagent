defmodule Ezagent.Email.Inbound.Authority do
  @moduledoc """
  The verified decision boundary for ephemeral inbound-email authority.

  The email projection and its ExternalMirror parent are freshly joined before
  one concrete, receiver-bound `session.send` artifact is issued. The artifact
  is used for one dispatch and is never persisted.
  """

  alias Ezagent.Email.Inbound.Authority.Reader
  alias Ezagent.Email.Inbound.Guard
  alias Ezagent.Email.InboundBinding
  alias Ezagent.ExternalMirror.BindingRow

  @type decision :: %{
          binding_row_id: String.t(),
          session_uri: URI.t(),
          principal_uri: URI.t(),
          caps: MapSet.t(Ezagent.Capability.t())
        }

  @spec issue(map()) :: {:ok, decision()} | {:reject, atom()} | {:retry, term()}
  def issue(record) when is_map(record) do
    local_address = record |> Map.get("to") |> normalize_address()

    with {:ok, evidence} <- read_evidence(local_address),
         {:ok, meta, row, session_uri, binding_actor} <- validate_evidence(evidence),
         :ok <- Guard.authenticated?(record, meta.target_id),
         {:ok, decision} <- issue_decision(meta, row, session_uri, binding_actor) do
      {:ok, decision}
    else
      {:reject, _reason} = reject -> reject
      {:retry, _reason} = retry -> retry
    end
  end

  defp read_evidence(nil), do: {:reject, :no_binding}

  defp read_evidence(local_address) do
    reader =
      :ezagent_plugin_email
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:reader, Reader)

    {:ok, reader.read(local_address)}
  rescue
    exception -> {:retry, {:binding_reader_failed, exception}}
  end

  defp validate_evidence(nil), do: {:reject, :no_binding}
  defp validate_evidence({%InboundBinding{}, nil}), do: {:reject, :binding_removed}

  defp validate_evidence({%InboundBinding{} = meta, %BindingRow{} = row}) do
    with {:ok, session_uri} <- parse_session(meta.session_uri),
         :ok <- matching_evidence(meta, row, session_uri),
         {:ok, binding_actor} <- parse_binding_actor(row.bound_by) do
      {:ok, meta, row, session_uri, binding_actor}
    end
  end

  defp matching_evidence(%InboundBinding{verification_status: status}, _row, _session_uri)
       when status != "verified",
       do: {:reject, :not_verified}

  defp matching_evidence(meta, row, session_uri) do
    workspace = session_uri |> Ezagent.Capability.workspace_of() |> URI.to_string()

    if meta.binding_row_id == row.id and
         meta.session_uri == row.session_uri and
         row.adapter_id == "email" and
         meta.target_id == row.target_id and
         meta.workspace_uri == row.workspace_uri and
         row.workspace_uri == workspace do
      :ok
    else
      {:reject, :binding_authority_mismatch}
    end
  end

  defp parse_session(session_uri) do
    case Ezagent.URI.new!(session_uri) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> {:reject, :binding_session_invalid}
    end
  rescue
    _ -> {:reject, :binding_session_invalid}
  end

  defp parse_binding_actor(bound_by) do
    case Ezagent.URI.new!(bound_by) do
      %URI{scheme: "entity"} = actor -> {:ok, actor}
      _ -> {:reject, :binding_actor_invalid}
    end
  rescue
    _ -> {:reject, :binding_actor_invalid}
  end

  defp issue_decision(_meta, row, session_uri, binding_actor) do
    workspace_name = Ezagent.URI.workspace_name!(session_uri)
    principal_uri = Ezagent.URI.entity(workspace_name, :user, "email-" <> short_id())

    case Ezagent.Cap.issue(
           {:rule, :verified_email_binding, binding_actor},
           principal_uri,
           send_cap(session_uri)
         ) do
      {:ok, cap} ->
        {:ok,
         %{
           binding_row_id: row.id,
           session_uri: session_uri,
           principal_uri: principal_uri,
           caps: MapSet.new([cap])
         }}

      {:error, reason} ->
        {:retry, {:cap_issue_failed, reason}}
    end
  rescue
    exception -> {:retry, {:cap_issue_failed, exception}}
  end

  defp send_cap(session_uri) do
    Ezagent.Capability.cap(
      :session,
      send_behavior(),
      :send,
      Ezagent.URI.instance(session_uri),
      Ezagent.Capability.workspace_of(session_uri)
    )
  end

  defp send_behavior do
    case Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, :send) do
      {:ok, behavior_module} -> behavior_module
      :error -> Ezagent.ActionSet.Session
    end
  end

  defp normalize_address(address) when is_binary(address),
    do: address |> String.trim() |> String.downcase()

  defp normalize_address(_address), do: nil

  defp short_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
