defmodule EzagentPluginHello.Router do
  @moduledoc """
  The hello front-desk routing logic: for each USER message, decide whether it
  goes to the page `builder` (generate/edit the page) or the read-only `concierge`
  (question / navigation), and DISPATCH the named action (`:rebuild` / `:answer`)
  to that member. Builder + concierge are native-flavor and receive via dispatch,
  not chat delivery (T2 I-1).

  The dispatch is a fire-and-forget `:cast` — the generation round-trip is slow
  and must never block the delivery path. Runs off the Behavior process in a
  supervised Task.

  ## Policy — intent × identity (the safety boundary is identity-first)

    * **Non-owner** member → ALWAYS `concierge`. The page-edit boundary is
      structural: a visitor can never reach the builder, regardless of what they
      type, and no LLM call is made for them.
    * **Owner** → intent classification (`Generator.classify_intent/2`): a
      change/create request → `builder`; a question / navigation → `concierge`.
  """

  alias EzagentPluginHello.{Generator, Members}

  # The front-desk's own worker roles (builder + concierge) — their output must
  # never re-route back (loop guard). The platform orchestrator (`requires:
  # ["orchestrator"]`) is NOT a hello worker.
  @worker_roles ["builder", "concierge", "sharer", "publisher", "dispatcher"]

  @doc """
  Route `user_text` (sent by `sender`) in `session_uri` to the builder's
  `:rebuild` or the concierge's `:answer` action. Spawns a supervised Task;
  returns `{:ok, pid}` (fire-and-forget). No-ops (`:ignored`) when
  `should_route?/2` rejects the sender — the loop guard.
  """
  @spec route(URI.t(), String.t(), URI.t()) :: {:ok, pid()} | {:error, term()} | :ignored
  def route(%URI{} = session_uri, user_text, %URI{} = sender) when is_binary(user_text) do
    if should_route?(session_uri, sender) do
      Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
        action = classify(user_text, owner?(session_uri, sender), session_uri)
        # F2 fail-closed: publish/share require a real owner. An ownerless
        # session (nil owner_uri, e.g. a pre-owner_uri old session) has
        # owner?→true (fail-open for builder/concierge) but must NOT grant
        # admin-level publish/share. Downgrade to concierge.
        action = guard_admin_actions(action, session_uri)
        dispatch_to_member(session_uri, action, user_text, sender)
      end)
    else
      :ignored
    end
  end

  @doc false
  def classify(_user_text, false = _owner?, _session_uri), do: :concierge

  def classify(user_text, true = _owner?, session_uri) do
    Generator.classify_intent(session_uri, user_text)
  end

  # F2 fail-closed: publish/share are admin-level actions. A session whose
  # owner_uri is nil (e.g. a pre-owner_uri old session — owner? returns true
  # as a fail-open for builder/concierge) must NOT grant these. Downgrade to
  # :concierge so a nil-owner session's visitors can't publish or share.
  defp guard_admin_actions(action, session_uri)
       when action in [:publisher, :sharer] do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{owner_uri: owner}} when not is_nil(owner) -> action
      {:ok, %{"owner_uri" => owner}} when not is_nil(owner) -> action
      _ -> :concierge
    end
  end

  defp guard_admin_actions(action, _session_uri), do: action

  # Dispatch a named action to a session member by role_name.
  defp dispatch_to_member(session_uri, role, user_text, sender) when is_atom(role) do
    role_name = Atom.to_string(role)

    {:ok, member_uri} = Members.role_uri(session_uri, role_name)

    action_atom =
      case role do
        :builder -> :rebuild
        :concierge -> :answer
        :sharer -> :share
        :publisher -> :publish
        :dispatcher -> :delegate_to_kanban
      end

    target =
      Ezagent.URI.with_action(member_uri, :agent, action_atom)

    session_uri_str = URI.to_string(session_uri)
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
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
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([signed_cap]),
          reply: :ignore
        },
        origin: :trusted_internal
      })
    end
  end

  @doc """
  Loop + multi-agent guard. Route a message UNLESS its sender is the
  front-desk itself or one of its own workers (builder / concierge) — those
  must never re-route (loop). Every other sender — a user OR an external agent
  — IS routed, which is how the front-desk accepts more than human messages.

  Fails CLOSED: if the `:session` members slice cannot be read AT ALL (no live
  Kind / a read miss), we cannot identify our own workers and therefore cannot
  guarantee this isn't a loop, so we do NOT route (`false`). A dropped message
  is recoverable (the user resends); an unguarded concierge→concierge loop is
  unbounded LLM calls.
  """
  @spec should_route?(URI.t(), URI.t()) :: boolean()
  def should_route?(%URI{} = session_uri, %URI{} = sender) do
    case Members.role_uris(session_uri, @worker_roles) do
      {:ok, own_uris} -> not Enum.any?(own_uris, &same_uri?(&1, sender))
      :error -> false
    end
  end

  # Read the session's owner from its `:session` slice (same source
  # `EzagentWeb.Socialware.SessionFeedChannel` uses). When an owner IS set, enforce
  # it (a non-owner is the read-only concierge — the page-edit boundary). When the
  # session is OWNERLESS (nil owner — e.g. a pre-owner_uri hello session), fail-OPEN
  # and treat the sender as the owner.
  defp owner?(session_uri, %URI{} = sender) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
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
