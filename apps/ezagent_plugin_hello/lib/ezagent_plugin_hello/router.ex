defmodule EzagentPluginHello.Router do
  @moduledoc """
  The Hello Session-ingress routing logic: for each user message, decide whether it
  is dispatched to a Session action: `:rebuild` (generate/edit the page),
  `:answer` (question / navigation), `:share`, `:publish`, or
  `:delegate_to_kanban`. The work does not require a separate agent identity.

  The dispatch is a fire-and-forget `:cast` — the generation round-trip is slow
  and must never block the delivery path. Runs off the Behavior process in a
  supervised Task.

  ## Policy — intent × identity (the safety boundary is identity-first)

    * **Non-owner** member → ALWAYS `:answer`. The page-edit boundary is
      structural: a visitor can never reach `:rebuild`, regardless of what they
      type, and no LLM call is made for them.
    * **Owner** → intent classification (`Generator.classify_intent/2`): a
      change/create request → `:rebuild`; a question / navigation → `:answer`.
  """

  alias EzagentPluginHello.{Generator, Members}

  @doc """
  Route `user_text` (sent by `sender`) in `session_uri` to a deterministic
  Session action. Spawns a supervised Task;
  returns `{:ok, pid}` (fire-and-forget). No-ops (`:ignored`) when
  `should_route?/2` rejects the sender — the loop guard.
  """
  @spec route(URI.t(), String.t(), URI.t()) :: {:ok, pid()} | {:error, term()} | :ignored
  def route(%URI{} = session_uri, user_text, %URI{} = sender) when is_binary(user_text) do
    route(session_uri, user_text, sender, nil)
  end

  @doc false
  def route(%URI{} = session_uri, user_text, %URI{} = sender, ref_id)
      when is_binary(user_text) do
    if completion_reply?(ref_id) do
      deliver_completion(ref_id, user_text)
    else
      route_user_message(session_uri, user_text, sender)
    end
  end

  defp route_user_message(%URI{} = session_uri, user_text, %URI{} = sender) do
    if should_route?(session_uri, sender) do
      Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
        action = classify(user_text, owner?(session_uri, sender), session_uri)
        # F2 fail-closed: publish/share require a real owner. An ownerless
        # session (nil owner_uri, e.g. a pre-owner_uri old session) has
        # owner?→true (fail-open for builder/concierge) but must NOT grant
        # admin-level publish/share. Downgrade to concierge.
        action = guard_admin_actions(action, session_uri)
        dispatch_to_session(session_uri, action, user_text, sender)
      end)
    else
      :ignored
    end
  end

  defp completion_reply?(ref_id),
    do: is_binary(ref_id) and String.starts_with?(ref_id, "hello-completion-")

  defp deliver_completion(ref_id, text) do
    case Registry.lookup(EzagentPluginHello.CompletionRegistry, ref_id) do
      [{pid, _}] when is_pid(pid) ->
        send(pid, {:hello_completion, ref_id, text})
        :ok

      _ ->
        :ignored
    end
  end

  @doc false
  def classify(_user_text, false = _owner?, _session_uri), do: :answer

  def classify(user_text, true = _owner?, session_uri) do
    Generator.classify_intent(session_uri, user_text)
  end

  # F2 fail-closed: publish/share are admin-level actions. A session whose
  # owner_uri is nil (e.g. a pre-owner_uri old session — owner? returns true
  # as a fail-open for builder/concierge) must NOT grant these. Downgrade to
  # :answer so a nil-owner session's visitors can't publish or share.
  defp guard_admin_actions(action, session_uri)
       when action in [:publish, :share] do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, %{owner_uri: owner}} when not is_nil(owner) -> action
      {:ok, %{"owner_uri" => owner}} when not is_nil(owner) -> action
      _ -> :answer
    end
  end

  defp guard_admin_actions(action, _session_uri), do: action

  # Dispatch the selected deterministic operation on the Session itself with a
  # target-issued cap scoped to that exact action.
  defp dispatch_to_session(session_uri, action, user_text, sender) when is_atom(action) do
    target = Ezagent.URI.with_action(session_uri, :hello_session_actions, action)

    session_uri_str = URI.to_string(session_uri)
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <-
           Ezagent.Cap.issue_for_action({:admin, admin}, session_uri, target) do
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{
          session_uri: session_uri_str,
          instruction: user_text,
          text: user_text,
          sender_uri: URI.to_string(sender)
        },
        ctx: %{
          caller: session_uri,
          authenticated_principal: session_uri,
          caps: MapSet.new([signed_cap]),
          reply: :ignore
        },
        origin: :trusted_internal
      })
    end
  end

  @doc """
  Loop + multi-agent guard. Session-authored narration/share output and the
  protected LLM member never re-enter ingress. Every other sender is routed.

  Fails CLOSED: if the `:session` members slice cannot be read AT ALL (no live
  Kind / a read miss), we cannot identify our own workers and therefore cannot
  guarantee this isn't a loop, so we do NOT route (`false`). A dropped message
  is recoverable (the user resends); an unguarded concierge→concierge loop is
  unbounded LLM calls.
  """
  @spec should_route?(URI.t(), URI.t()) :: boolean()
  def should_route?(%URI{} = session_uri, %URI{} = sender) do
    if same_uri?(session_uri, sender) do
      false
    else
      case Members.role_uris(session_uri, ["llm"]) do
        {:ok, own_agent_uris} -> Enum.all?(own_agent_uris, &(not same_uri?(&1, sender)))
        :error -> false
      end
    end
  end

  # Read the session's owner from its `:session` slice (same source
  # `EzagentWeb.Socialware.SessionFeedChannel` uses). When an owner IS set, enforce
  # it (a non-owner is the read-only concierge — the page-edit boundary). When the
  # session is OWNERLESS (nil owner — e.g. a pre-owner_uri hello session), fail-OPEN
  # and treat the sender as the owner.
  defp owner?(session_uri, %URI{} = sender) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, slice} when is_map(slice) ->
        case Map.get(slice, :owner_uri) || Map.get(slice, "owner_uri") do
          nil -> true
          owner -> same_uri?(owner, sender)
        end

      _ ->
        true
    end
  end

  defp same_uri?(%URI{} = owner, %URI{} = sender),
    do: URI.to_string(owner) == URI.to_string(sender)

  defp same_uri?(owner, %URI{} = sender) when is_binary(owner),
    do: owner == URI.to_string(sender)

  defp same_uri?(_, _), do: false
end
