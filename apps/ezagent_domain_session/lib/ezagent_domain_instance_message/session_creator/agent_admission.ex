defmodule EzagentDomainInstanceMessage.SessionCreator.AgentAdmission do
  @moduledoc """
  Durable admission state for credential-gated session role agents.

  The session template declaration remains authoritative for role, recipe,
  flavor, provider profile, and revision. Admission rows freeze the provider
  profile needed to revalidate a joined credential with the same semantics used
  at completion. They contain only durable, non-secret state; credential material
  stays in the flavor-owned agent surface.
  """

  alias Ezagent.Agent.CredentialConnection
  alias Ezagent.Entity.Session
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionReconciliation
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionState, as: State
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupport
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @active_statuses [:authenticating, :materializing]

  @type status :: :pending_auth | :authenticating | :materializing | :joined | :failed
  @type failure_code ::
          nil | :authentication_failed | :connection_cancelled | :connection_timed_out

  @type admission :: %{
          required(:status) => status(),
          required(:flavor) => String.t(),
          required(:provider) => String.t() | nil,
          required(:role_name) => String.t(),
          required(:template_revision) => String.t(),
          required(:attempt_id) => String.t() | nil,
          required(:provisional_agent_uri) => String.t() | nil,
          required(:expires_at) => String.t() | nil,
          required(:connection) => CredentialConnection.descriptor(),
          required(:failure_code) => failure_code()
        }

  @doc "List durable admission rows for a session, sorted by role name."
  @spec list(URI.t()) :: [admission()]
  def list(%URI{scheme: "session"} = session_uri) do
    session_uri
    |> State.admissions()
    |> Map.values()
    |> Enum.sort_by(& &1.role_name)
  end

  @doc false
  @spec reconcile_auth_failure(URI.t()) :: :ok | {:error, term()}
  defdelegate reconcile_auth_failure(agent_uri), to: AgentAdmissionReconciliation

  @doc "Reconcile every active credential admission owned by one session."
  @spec reconcile(URI.t()) :: :ok | {:error, [{String.t(), String.t(), term()}]}
  def reconcile(%URI{scheme: "session"} = session_uri) do
    failures =
      session_uri
      |> list()
      |> Enum.filter(&(&1.status in @active_statuses))
      |> Enum.reduce([], fn admission, failures ->
        case reconcile_attempt(session_uri, admission.role_name, admission.attempt_id) do
          :ok -> failures
          {:error, reason} -> [{admission.role_name, admission.attempt_id, reason} | failures]
        end
      end)

    case Enum.reverse(failures) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc """
  Start or resume the one provisional agent for a gated role.

  `actor_uri` must own the session. `caps` are the actor's current authorized
  context and are never persisted.
  """
  @spec begin(URI.t(), String.t(), URI.t(), Enumerable.t()) ::
          {:ok, admission()} | {:error, term()}
  def begin(
        %URI{scheme: "session"} = session_uri,
        role_name,
        %URI{} = actor_uri,
        caps
      )
      when is_binary(role_name) do
    State.with_lock(session_uri, fn ->
      with :ok <- require_owner(session_uri, actor_uri),
           {:ok, declaration, revision} <- declared_gated_role(session_uri, role_name),
           {:ok, connection} <- connection_for(declaration),
           {:ok, admission} <-
             begin_from_current(
               session_uri,
               actor_uri,
               caps,
               declaration,
               revision,
               connection
             ) do
        State.transition_ok(:begin, session_uri, admission)
        {:ok, admission}
      else
        {:error, reason} = error ->
          State.transition_failed(:begin, session_uri, role_name, reason)
          error
      end
    end)
  end

  @doc """
  Validate the active provisional agent, bind its declared recipe, and join it.
  """
  @spec complete(URI.t(), String.t(), String.t(), {URI.t(), Enumerable.t()}) ::
          {:ok, admission()} | {:error, term()}
  def complete(
        %URI{scheme: "session"} = session_uri,
        role_name,
        attempt_id,
        {%URI{} = actor_uri, caps}
      )
      when is_binary(role_name) and is_binary(attempt_id) do
    State.with_lock(session_uri, fn ->
      result =
        with :ok <- require_owner(session_uri, actor_uri),
             {:ok, declaration, revision} <- declared_gated_role(session_uri, role_name),
             {:ok, current} <-
               active_attempt(session_uri, declaration, revision, attempt_id),
             {:ok, agent_uri} <- provisional_uri(current),
             {:ok, credential_status} <-
               Ezagent.Domain.Agent.read_credential_status(
                 agent_uri,
                 actor_ctx(actor_uri, caps),
                 backend_profile: provider_of(declaration)
               ),
             :ok <- credential_authenticated(credential_status, current.connection),
             {:ok, joined} <-
               complete_authenticated(
                 session_uri,
                 actor_uri,
                 caps,
                 declaration,
                 current,
                 agent_uri,
                 attempt_id
               ) do
          {:ok, joined}
        else
          {:error, :authentication_failed} ->
            fail_active_attempt(
              session_uri,
              role_name,
              attempt_id,
              actor_uri,
              caps,
              :authentication_failed
            )

          {:error, reason} ->
            State.transition_failed(:complete, session_uri, role_name, reason)
            {:error, reason}
        end

      result
    end)
  end

  def complete(_session_uri, _role_name, _attempt_id, _actor_and_caps),
    do: {:error, :invalid_agent_admission_completion}

  defp reconcile_attempt(session_uri, role_name, attempt_id) do
    State.with_lock(session_uri, fn ->
      with {:ok, declaration, revision} <- declared_gated_role(session_uri, role_name),
           {:ok, attempt} <-
             reconcilable_attempt(session_uri, declaration, revision, attempt_id) do
        reconcile_current_attempt(session_uri, declaration, attempt)
      end
    end)
  end

  defp reconcile_current_attempt(_session_uri, _declaration, :settled), do: :ok

  defp reconcile_current_attempt(session_uri, declaration, {:active, current}) do
    with {:ok, owner_uri} <- Session.owner(session_uri),
         {:ok, agent_uri} <- provisional_uri(current),
         caps <-
           EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri),
         {:ok, credential_status} <-
           Ezagent.Domain.Agent.read_credential_status(
             agent_uri,
             actor_ctx(owner_uri, caps),
             backend_profile: provider_of(declaration)
           ) do
      reconcile_credential_status(
        credential_status,
        session_uri,
        owner_uri,
        caps,
        declaration,
        current,
        agent_uri
      )
    end
  end

  defp reconcile_credential_status(
         %{status: :authenticated},
         session_uri,
         owner_uri,
         caps,
         declaration,
         current,
         agent_uri
       ) do
    case complete_authenticated(
           session_uri,
           owner_uri,
           caps,
           declaration,
           current,
           agent_uri,
           current.attempt_id
         ) do
      {:ok, _joined} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_credential_status(
         %{status: status},
         _session_uri,
         _owner_uri,
         _caps,
         _declaration,
         _current,
         _agent_uri
       )
       when status in [:missing, :unknown],
       do: :ok

  defp reconcile_credential_status(
         %{status: status},
         _session_uri,
         _owner_uri,
         _caps,
         _declaration,
         _current,
         _agent_uri
       ),
       do: {:error, {:unsupported_credential_status, status}}

  @doc "Cancel an active candidate. Repeated cancellation of the same attempt is idempotent."
  @spec cancel(URI.t(), String.t(), String.t(), {URI.t(), Enumerable.t()}) ::
          {:ok, admission()} | {:error, term()}
  def cancel(
        %URI{scheme: "session"} = session_uri,
        role_name,
        attempt_id,
        {%URI{} = actor_uri, caps}
      )
      when is_binary(role_name) and is_binary(attempt_id) do
    State.with_lock(session_uri, fn ->
      with :ok <- require_owner(session_uri, actor_uri),
           {:ok, declaration, revision} <- declared_gated_role(session_uri, role_name),
           {:ok, current} <-
             cancellable_attempt(session_uri, declaration, revision, attempt_id),
           {:ok, failed} <-
             cancel_current(
               session_uri,
               current,
               actor_uri,
               caps,
               :connection_cancelled
             ) do
        State.transition_ok(:cancel, session_uri, failed)
        {:ok, failed}
      else
        {:error, reason} = error ->
          State.transition_failed(:cancel, session_uri, role_name, reason)
          error
      end
    end)
  end

  def cancel(_session_uri, _role_name, _attempt_id, _actor_and_caps),
    do: {:error, :invalid_agent_admission_cancellation}

  @doc "Expire an attempt by its durable creation-attempt ID."
  @spec expire(URI.t(), String.t()) :: {:ok, admission()} | {:error, term()}
  def expire(%URI{scheme: "session"} = session_uri, attempt_id)
      when is_binary(attempt_id) do
    case Enum.find(list(session_uri), &(&1.attempt_id == attempt_id)) do
      %{role_name: role_name} ->
        with {:ok, owner_uri} <- Session.owner(session_uri) do
          caps =
            EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

          State.with_lock(session_uri, fn ->
            case declared_gated_role(session_uri, role_name) do
              {:ok, declaration, revision} ->
                expire_current_or_stale(
                  session_uri,
                  declaration,
                  revision,
                  attempt_id,
                  owner_uri,
                  caps
                )

              {:error, _declaration_reason} ->
                expire_undeclared_row(
                  session_uri,
                  role_name,
                  attempt_id,
                  owner_uri,
                  caps
                )
            end
          end)
        end

      nil ->
        {:error, :stale_agent_admission_attempt}
    end
  end

  defp expire_current_or_stale(
         session_uri,
         declaration,
         revision,
         attempt_id,
         owner_uri,
         caps
       ) do
    role_name = field(declaration, :role_name)

    with {:ok, row_state} <- reconcile_row(session_uri, declaration, revision) do
      case row_state do
        {:current, _current} ->
          with {:ok, cancellable} <-
                 cancellable_attempt(session_uri, declaration, revision, attempt_id),
               {:ok, failed} <-
                 cancel_current(
                   session_uri,
                   cancellable,
                   owner_uri,
                   caps,
                   :connection_timed_out
                 ) do
            State.transition_ok(:expire, session_uri, failed)
            {:ok, failed}
          end

        {:stale, %{attempt_id: ^attempt_id} = stale} ->
          expired = failed_row(stale, :connection_timed_out)
          State.transition_ok(:expire, session_uri, expired)
          {:ok, expired}

        _ ->
          {:error, :stale_agent_admission_attempt}
      end
    else
      {:error, reason} = error ->
        State.transition_failed(:expire, session_uri, role_name, reason)
        error
    end
  end

  defp expire_undeclared_row(session_uri, role_name, attempt_id, _owner_uri, _caps) do
    case Map.get(State.admissions(session_uri), role_name) do
      %{attempt_id: ^attempt_id} = stale ->
        with :ok <- retire_or_clear_stale_row(session_uri, stale) do
          expired = failed_row(stale, :connection_timed_out)
          State.transition_ok(:expire, session_uri, expired)
          {:ok, expired}
        end

      _ ->
        {:error, :stale_agent_admission_attempt}
    end
  end

  @doc false
  @spec current(URI.t(), map()) :: {:ok, admission() | nil} | {:error, term()}
  def current(%URI{scheme: "session"} = session_uri, declaration) when is_map(declaration) do
    role_name = field(declaration, :role_name)

    State.with_lock(session_uri, fn ->
      with {:ok, current_declaration, revision} <-
             declared_gated_role(session_uri, role_name),
           :ok <- same_declaration(current_declaration, declaration),
           {:ok, row_state} <-
             reconcile_row(session_uri, current_declaration, revision) do
        case row_state do
          {:current, row} -> {:ok, row}
          :missing -> {:ok, nil}
          {:stale, _row} -> {:ok, nil}
        end
      end
    end)
  end

  @doc false
  @spec defer(URI.t(), map()) :: {:ok, admission()} | {:error, term()}
  def defer(%URI{scheme: "session"} = session_uri, declaration) when is_map(declaration) do
    role_name = field(declaration, :role_name)

    State.with_lock(session_uri, fn ->
      with {:ok, current_declaration, revision} <-
             declared_gated_role(session_uri, role_name),
           :ok <- same_declaration(current_declaration, declaration),
           {:ok, connection} <- connection_for(current_declaration),
           {:ok, row_state} <-
             reconcile_row(session_uri, current_declaration, revision) do
        case row_state do
          {:current, %{status: status} = current}
          when status in @active_statuses or status == :joined ->
            {:ok, current}

          {:current, %{status: :failed} = failed} ->
            {:ok, failed}

          {:current, _pending} ->
            put_pending(session_uri, current_declaration, revision, connection)

          :missing ->
            put_pending(session_uri, current_declaration, revision, connection)

          {:stale, _retired} ->
            put_pending(session_uri, current_declaration, revision, connection)
        end
      end
    end)
  end

  defp put_pending(session_uri, declaration, revision, connection) do
    pending =
      admission_row(
        declaration,
        revision,
        connection,
        :pending_auth
      )

    with :ok <- State.put_admission(session_uri, pending) do
      State.transition_ok(:defer, session_uri, pending)
      {:ok, pending}
    end
  end

  @doc false
  @spec clear(URI.t(), map()) :: :ok | {:error, term()}
  def clear(%URI{scheme: "session"} = session_uri, declaration) when is_map(declaration) do
    role_name = field(declaration, :role_name)

    State.with_lock(session_uri, fn ->
      with {:ok, current_declaration, revision} <-
             declared_gated_role(session_uri, role_name),
           :ok <- same_declaration(current_declaration, declaration),
           {:ok, row_state} <-
             reconcile_row(session_uri, current_declaration, revision) do
        case row_state do
          {:current, %{status: status}} when status in @active_statuses ->
            {:error, :agent_admission_active}

          {:current, _row} ->
            State.delete_admission(session_uri, role_name)

          :missing ->
            :ok

          {:stale, _retired} ->
            :ok
        end
      end
    end)
  end

  defp begin_from_current(
         session_uri,
         actor_uri,
         caps,
         declaration,
         revision,
         connection
       ) do
    with {:ok, row_state} <- reconcile_row(session_uri, declaration, revision) do
      case row_state do
        {:current, %{status: status} = current} when status in @active_statuses ->
          {:ok, current}

        {:current, %{status: :joined} = joined} ->
          {:ok, joined}

        :missing ->
          {:error, :agent_admission_not_pending}

        {:current, current} when current.status in [:pending_auth, :failed] ->
          start_provisional(
            session_uri,
            actor_uri,
            caps,
            declaration,
            revision,
            connection
          )

        {:stale, _retired} ->
          {:error, :stale_agent_admission_declaration}
      end
    end
  end

  defp start_provisional(session_uri, actor_uri, caps, declaration, revision, connection) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    with {:ok, agent_uri, attempt_id} <-
           DefinitionAgents.spawn_provisional(
             session_uri,
             workspace_uri,
             actor_uri,
             declaration
           ) do
      agent_uri_str = URI.to_string(agent_uri)

      authenticating =
        declaration
        |> admission_row(revision, connection, :authenticating)
        |> Map.put(:attempt_id, attempt_id)
        |> Map.put(:provisional_agent_uri, agent_uri_str)
        |> Map.put(:expires_at, State.authentication_deadline())

      case State.put_admission(session_uri, authenticating) do
        :ok ->
          {:ok, authenticating}

        {:error, reason} ->
          original = {:agent_admission_record_failed, reason}

          case DefinitionAgents.cleanup_provisional(
                 session_uri,
                 actor_uri,
                 agent_uri,
                 attempt_id,
                 actor_ctx(actor_uri, caps),
                 :admission_record_failed
               ) do
            :ok -> {:error, original}
            {:error, cleanup_reason} -> {:error, {original, {:cleanup_failed, cleanup_reason}}}
          end
      end
    end
  end

  defp active_attempt(session_uri, declaration, revision, attempt_id) do
    with {:ok, row_state} <- reconcile_row(session_uri, declaration, revision) do
      case row_state do
        {:current, %{status: status, attempt_id: ^attempt_id} = current}
        when status in @active_statuses ->
          {:ok, current}

        {:stale, _retired} ->
          {:error, :stale_agent_admission_declaration}

        _ ->
          {:error, :stale_agent_admission_attempt}
      end
    end
  end

  defp reconcilable_attempt(session_uri, declaration, revision, attempt_id) do
    with {:ok, row_state} <- reconcile_row(session_uri, declaration, revision) do
      case row_state do
        {:current, %{status: status, attempt_id: ^attempt_id} = current}
        when status in @active_statuses ->
          {:ok, {:active, current}}

        {:current, %{status: status, attempt_id: ^attempt_id}}
        when status in [:joined, :failed] ->
          {:ok, :settled}

        {:stale, _retired} ->
          {:error, :stale_agent_admission_declaration}

        _ ->
          {:error, :stale_agent_admission_attempt}
      end
    end
  end

  defp cancellable_attempt(session_uri, declaration, revision, attempt_id) do
    with {:ok, row_state} <- reconcile_row(session_uri, declaration, revision) do
      case row_state do
        {:current, %{status: :failed, attempt_id: ^attempt_id} = current} ->
          {:ok, current}

        {:current, %{status: status, attempt_id: ^attempt_id} = current}
        when status in @active_statuses ->
          {:ok, current}

        {:stale, _retired} ->
          {:error, :stale_agent_admission_declaration}

        _ ->
          {:error, :stale_agent_admission_attempt}
      end
    end
  end

  defp cancel_current(_session_uri, %{status: :failed} = current, _actor, _caps, _reason),
    do: {:ok, current}

  defp cancel_current(session_uri, current, actor_uri, caps, failure_code) do
    do_cancel_current(session_uri, current, actor_uri, caps, failure_code)
  end

  defp do_cancel_current(session_uri, current, actor_uri, caps, failure_code) do
    with {:ok, agent_uri} <- provisional_uri(current) do
      case DefinitionAgents.cleanup_provisional(
             session_uri,
             actor_uri,
             agent_uri,
             current.attempt_id,
             actor_ctx(actor_uri, caps),
             failure_code
           ) do
        :ok ->
          put_failed(session_uri, current, failure_code)

        {:error, cleanup_reason} ->
          {:error, cleanup_reason}
      end
    end
  end

  defp fail_active_attempt(
         session_uri,
         role_name,
         attempt_id,
         actor_uri,
         caps,
         failure_code
       ) do
    current = Map.get(State.admissions(session_uri), role_name)

    with %{attempt_id: ^attempt_id} <- current,
         {:ok, failed} <-
           cancel_current(session_uri, current, actor_uri, caps, failure_code) do
      State.transition_failed(:complete, session_uri, role_name, failure_code)
      {:error, failure_code, failed}
    else
      {:error, reason} ->
        State.transition_failed(:complete, session_uri, role_name, reason)
        {:error, reason}

      _ ->
        {:error, :stale_agent_admission_attempt}
    end
  end

  defp complete_authenticated(
         session_uri,
         actor_uri,
         caps,
         declaration,
         current,
         agent_uri,
         attempt_id
       ) do
    do_complete_authenticated(
      session_uri,
      actor_uri,
      caps,
      declaration,
      current,
      agent_uri,
      attempt_id
    )
  end

  defp do_complete_authenticated(
         session_uri,
         actor_uri,
         caps,
         declaration,
         current,
         agent_uri,
         attempt_id
       ) do
    case put_status(session_uri, current, :materializing, nil) do
      {:ok, materializing} ->
        result =
          with :ok <-
                 DefinitionAgents.complete_provisional(
                   session_uri,
                   actor_uri,
                   declaration,
                   agent_uri,
                   attempt_id,
                   actor_ctx(actor_uri, caps)
                 ),
               {:ok, joined} <- put_joined(session_uri, materializing) do
            {:ok, joined}
          end

        case result do
          {:ok, joined} = ok ->
            State.transition_ok(:complete, session_uri, joined)
            ok

          {:error, reason} ->
            fail_authenticated_completion(
              session_uri,
              current.role_name,
              materializing,
              actor_uri,
              caps,
              reason
            )
        end

      {:error, reason} ->
        fail_authenticated_completion(
          session_uri,
          current.role_name,
          current,
          actor_uri,
          caps,
          reason
        )
    end
  end

  defp fail_authenticated_completion(
         session_uri,
         role_name,
         cleanup_current,
         actor_uri,
         caps,
         reason
       ) do
    case cancel_current(session_uri, cleanup_current, actor_uri, caps, nil) do
      {:ok, _failed} ->
        State.transition_failed(:complete, session_uri, role_name, reason)
        {:error, reason}

      {:error, cleanup_reason} ->
        State.transition_failed(:complete, session_uri, role_name, cleanup_reason)
        {:error, {reason, cleanup_reason}}
    end
  end

  defp credential_authenticated(%{status: :authenticated}, _connection), do: :ok
  defp credential_authenticated(%{status: :n_a}, :not_required), do: :ok
  defp credential_authenticated(_status, _connection), do: {:error, :authentication_failed}

  if Mix.env() == :test do
    defp joined_write_fault(current) do
      case Application.get_env(:ezagent_domain_session, :agent_admission_put_joined_fault) do
        nil -> :ok
        fault when is_function(fault, 1) -> fault.(current)
        reason -> {:error, reason}
      end
    end
  else
    defp joined_write_fault(_current), do: :ok
  end

  defp put_status(session_uri, current, status, failure_code) do
    next = %{current | status: status, failure_code: failure_code, expires_at: nil}
    with :ok <- State.put_admission(session_uri, next), do: {:ok, next}
  end

  defp put_joined(session_uri, current) do
    next = %{current | status: :joined, expires_at: nil, failure_code: nil}

    with :ok <- joined_write_fault(next),
         :ok <- State.put_admission(session_uri, next),
         do: {:ok, next}
  end

  defp put_failed(session_uri, current, failure_code) do
    failed = failed_row(current, failure_code)

    with :ok <- State.put_admission(session_uri, failed), do: {:ok, failed}
  end

  defp failed_row(current, failure_code) do
    Map.merge(current, %{
      status: :failed,
      provisional_agent_uri: nil,
      expires_at: nil,
      failure_code: failure_code
    })
  end

  defp admission_row(declaration, revision, connection, status) do
    %{
      status: status,
      flavor: field(declaration, :flavor),
      provider: provider_of(declaration),
      role_name: field(declaration, :role_name),
      template_revision: revision,
      attempt_id: nil,
      provisional_agent_uri: nil,
      expires_at: nil,
      connection: connection,
      failure_code: nil
    }
  end

  defp declared_gated_role(session_uri, role_name) do
    working_copy = Session.read_template_working_copy(session_uri)
    declarations = Map.get(working_copy, :member_declarations, [])

    case Enum.find(declarations, &(field(&1, :role_name) == role_name)) do
      nil ->
        {:error, :undeclared_agent_admission_role}

      declaration ->
        if DefinitionAgentSupport.credential_admission_of(declaration) ==
             :before_session_join do
          with {:ok, revision} <- template_revision(working_copy) do
            {:ok, declaration, revision}
          end
        else
          {:error, :role_does_not_require_agent_admission}
        end
    end
  end

  defp template_revision(%{session_template_uri: %URI{} = uri}),
    do: {:ok, URI.to_string(uri)}

  defp template_revision(_working_copy), do: {:error, :missing_session_template_revision}

  defp connection_for(declaration) do
    CredentialConnection.for_flavor(field(declaration, :flavor),
      role: declaration
    )
  end

  defp validate_row(current, declaration, revision) do
    if current.role_name == field(declaration, :role_name) and
         current.flavor == field(declaration, :flavor) and
         field(current, :provider) == provider_of(declaration) and
         current.template_revision == revision do
      :ok
    else
      {:error, :stale_agent_admission_declaration}
    end
  end

  defp reconcile_row(session_uri, declaration, revision) do
    role_name = field(declaration, :role_name)

    case Map.get(State.admissions(session_uri), role_name) do
      nil ->
        {:ok, :missing}

      current ->
        with {:ok, current} <-
               State.backfill_provider_under_lock(
                 session_uri,
                 current,
                 declaration,
                 revision
               ) do
          case validate_row(current, declaration, revision) do
            :ok ->
              {:ok, {:current, current}}

            {:error, :stale_agent_admission_declaration} ->
              with :ok <- retire_or_clear_stale_row(session_uri, current) do
                {:ok, {:stale, current}}
              end
          end
        end
    end
  end

  defp retire_or_clear_stale_row(session_uri, %{status: status} = current)
       when status in @active_statuses do
    with {:ok, owner_uri} <- Session.owner(session_uri),
         {:ok, agent_uri} <- provisional_uri(current),
         caps <-
           EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri) do
      case DefinitionAgents.cleanup_provisional(
             session_uri,
             owner_uri,
             agent_uri,
             current.attempt_id,
             actor_ctx(owner_uri, caps),
             :stale_agent_admission_declaration
           ) do
        :ok -> State.delete_admission(session_uri, current.role_name)
        {:error, cleanup_reason} -> {:error, cleanup_reason}
      end
    else
      {:error, _reason} = error -> error
      other -> {:error, {:stale_agent_admission_cleanup_failed, other}}
    end
  end

  defp retire_or_clear_stale_row(session_uri, current),
    do: State.delete_admission(session_uri, current.role_name)

  defp same_declaration(current, requested) do
    if field(current, :role_name) == field(requested, :role_name) and
         field(current, :flavor) == field(requested, :flavor) and
         field(current, :provider) == provider_of(requested) and
         field(current, :recipe) == field(requested, :recipe) do
      :ok
    else
      {:error, :forged_agent_admission_declaration}
    end
  end

  defp provisional_uri(%{provisional_agent_uri: value})
       when is_binary(value) and value != "" do
    case Ezagent.URI.parse(value) do
      {:ok, %URI{scheme: "entity"} = uri} -> {:ok, uri}
      _ -> {:error, :invalid_provisional_agent_uri}
    end
  end

  defp provisional_uri(_current), do: {:error, :missing_provisional_agent_uri}

  defp require_owner(session_uri, actor_uri) do
    case Session.owner(session_uri) do
      {:ok, owner_uri} ->
        if same_uri?(owner_uri, actor_uri), do: :ok, else: {:error, :agent_admission_not_owner}

      _ ->
        {:error, :agent_admission_owner_unavailable}
    end
  end

  defp actor_ctx(actor_uri, caps) do
    %{
      caller: actor_uri,
      authenticated_principal: actor_uri,
      caps: MapSet.new(caps)
    }
  end

  defp provider_of(declaration), do: field(declaration, :provider)

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
