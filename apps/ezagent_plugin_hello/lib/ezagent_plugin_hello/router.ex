defmodule EzagentPluginHello.Router do
  @moduledoc """
  The `hello.orchestrator` routing logic: for each USER message, decide whether it
  goes to the page `builder` (generate/edit the page) or the read-only `concierge`
  (question / navigation), ensure that agent exists (spawn on demand), and trigger
  its generation.

  NOT `Ezagent.Router` (the framework dispatch router) — this is hello-internal
  message routing, invoked from `Ezagent.ActionSet.HelloOrchestrator`.

  ## Policy — intent × identity (the safety boundary is identity-first)

    * **Non-owner** member → ALWAYS `concierge`. The page-edit boundary is
      structural: a visitor can never reach the builder, regardless of what they
      type, and no LLM call is made for them.
    * **Owner** → intent classification (`Generator.classify_intent/1`): a
      change/create request → `builder`; a question / navigation → `concierge`.

  Runs off the Behavior process in a supervised Task (the owner intent LLM call +
  the generation round-trip are slow; they must never block dispatch).
  """

  alias EzagentPluginHello.{Generator, Members}

  @roles ["orchestrator", "builder", "concierge"]

  @doc """
  Route `user_text` (sent by `sender`) in `session_uri` to the builder or concierge.
  Spawns a supervised Task; returns its `{:ok, pid}` (fire-and-forget). No-ops
  (`:ignored`) when `should_route?/2` rejects the sender (the orchestrator's own
  outbound or one of its own builder/concierge members) — the loop guard.
  """
  @spec route(URI.t(), String.t(), URI.t()) :: {:ok, pid()} | {:error, term()} | :ignored
  def route(%URI{} = session_uri, user_text, %URI{} = sender) when is_binary(user_text) do
    if should_route?(session_uri, sender) do
      Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
        case decide(owner?(session_uri, sender), user_text) do
          :builder ->
            Generator.generate(session_uri, user_text)

          :concierge ->
            # The builder + concierge are now ALWAYS-materialized members
            # (`Definition.roles`), so no on-demand spawn — resolve the concierge
            # member by role and attribute its reply. Fail-loud if unresolved (a
            # materialized session always has one).
            {:ok, concierge_uri} = Members.role_uri(session_uri, "concierge")
            Generator.concierge_answer(session_uri, user_text, concierge_uri)
        end
      end)
    else
      :ignored
    end
  end

  @doc """
  Loop + multi-agent guard. Route a message UNLESS its sender is the
  orchestrator itself or one of its own managed members (builder / concierge) —
  those are the orchestrator's OWN workers, whose output must never re-route
  (loop). Every other sender — a user OR an external agent — IS routed, which is
  how the orchestrator accepts more than human messages.

  Fails CLOSED: if the `:session` members slice cannot be read AT ALL (no live
  Kind / a read miss), we cannot identify our own workers and therefore cannot
  guarantee this isn't a loop, so we do NOT route (`false`). A dropped message
  is recoverable (the user resends); an unguarded concierge→concierge loop is
  unbounded LLM calls. This is distinct from the readable-but-role-not-yet-
  materialized case (a fresh/half-built session), which still routes normally —
  see `Members.role_uris/2`, which resolves all roles from a SINGLE read so
  "slice unreadable" and "slice readable, role just not filled" aren't conflated.
  """
  @spec should_route?(URI.t(), URI.t()) :: boolean()
  def should_route?(%URI{} = session_uri, %URI{} = sender) do
    case Members.role_uris(session_uri, @roles) do
      {:ok, own_uris} -> not Enum.any?(own_uris, &same_uri?(&1, sender))
      :error -> false
    end
  end

  @doc """
  The routing policy — identity FIRST (the page-edit security boundary), then
  intent. A non-owner is ALWAYS routed to the read-only concierge, no matter what
  they type and with NO LLM call; only the owner's message is intent-classified
  (build vs ask). Pure w.r.t. identity so the boundary is unit-testable; the
  owner branch delegates to the LLM classifier.
  """
  @spec decide(boolean(), String.t()) :: :builder | :concierge
  def decide(false = _owner?, _user_text), do: :concierge
  def decide(true = _owner?, user_text), do: Generator.classify_intent(user_text)

  # Read the session's owner from its `:session` slice (same source
  # `EzagentWeb.Socialware.SessionFeedChannel` uses). When an owner IS set, enforce
  # it (a non-owner is the read-only concierge — the page-edit boundary). When the
  # session is OWNERLESS (nil owner — e.g. a pre-owner_uri hello session), fail-OPEN
  # and treat the sender as the owner: there is no owner to protect, anon/non-members
  # cannot speak here anyway, and stranding the operator (everything → concierge, no
  # page ever builds) is the worse failure. Mirrors the legacy `ownerless → builder`
  # default the deterministic router used.
  defp owner?(session_uri, %URI{} = sender) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, slice} when is_map(slice) ->
        case Map.get(slice, :owner_uri) || Map.get(slice, "owner_uri") do
          nil -> true
          owner -> same_uri?(owner, sender)
        end

      _ ->
        # Can't read the slice — fail-open so a transient read miss never strands
        # the operator. (Anon/non-members are already gated out upstream.)
        true
    end
  end

  defp same_uri?(%URI{} = owner, %URI{} = sender),
    do: URI.to_string(owner) == URI.to_string(sender)

  defp same_uri?(owner, %URI{} = sender) when is_binary(owner),
    do: owner == URI.to_string(sender)

  defp same_uri?(_, _), do: false
end
