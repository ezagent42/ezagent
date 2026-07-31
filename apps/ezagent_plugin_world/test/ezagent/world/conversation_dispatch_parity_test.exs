defmodule Ezagent.World.ConversationDispatchParityTest do
  @moduledoc """
  Durable parity gate for the `world:dispatch` conversation surface (#224).

  `EzagentPluginWorld.WorldLive` routes a conversation action to
  `Ezagent.World.ConversationActions.handle_dispatch/3` ONLY when the action is
  a member of `Ezagent.World.DispatchContract.actions(:conversation)` — anything
  else falls through to the catch-all and returns `error:unsupported_action`.
  So a handler clause whose action string is missing from the contract is DEAD:
  the React client dispatches it, but it never reaches its handler. That is
  exactly the #224 defect (`session.publish_template` / `session.fork_config` /
  `session.assign_role`).

  This gate enumerates — by parsing the module's OWN source AST, not a
  hand-copied list — every action string `handle_dispatch/3` matches, and
  asserts each is either in the `:conversation` contract or in the documented
  exemption set below. It fails loudly the next time someone adds a
  `handle_dispatch` clause without wiring the contract, closing the whole class.

  ## Exemptions (handled but intentionally NOT in the contract)

  `turn.claim`, `turn.settle`, `surface.approve`, `supervisor.verdict` have
  `handle_dispatch/3` clauses but NO `world:dispatch` caller: the React client
  (`assets/src`) never dispatches these strings. Their underlying session
  behaviors (`:turn` / `:surface` / `:supervisor_approval`) are driven through
  the DOMAIN invocation path (`Ezagent.URI.with_action(session_uri, :turn,
  :claim)` etc.), never the browser `world:dispatch` bridge. Adding them to the
  `:conversation` contract would expose un-wired handlers with no frontend. The
  frontend-absence assertion below keeps this exemption honest: if a client ever
  dispatches one of these via `world:dispatch`, this test goes red and forces it
  into the contract (the same latent bug as #224), rather than being silently
  covered by the exemption.
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.DispatchContract

  @unwired_exemptions ~w(turn.claim turn.settle surface.approve supervisor.verdict)

  test "every world:dispatch conversation handler is in the :conversation contract (or explicitly exempt)" do
    handled = handled_action_strings()

    # Sanity: the AST scanner actually found the clauses (a wrong source path
    # would otherwise pass vacuously on an empty set).
    assert "chat.send" in handled
    assert "session.publish_template" in handled
    assert "session.assign_role" in handled

    contract = MapSet.new(DispatchContract.actions(:conversation))
    exempt = MapSet.new(@unwired_exemptions)

    missing =
      Enum.reject(handled, &(MapSet.member?(contract, &1) or MapSet.member?(exempt, &1)))

    assert missing == [],
           "ConversationActions.handle_dispatch/3 handles action(s) that are neither in " <>
             "DispatchContract.actions(:conversation) nor exempt: #{inspect(missing)}. " <>
             "A world:dispatch action that is not in the contract falls through to " <>
             "error:unsupported_action (the #224 defect). Add each to the :conversation " <>
             "list in dispatch_contract.ex (if the React client dispatches it), or add a " <>
             "documented exemption here (if it is reached via another path)."
  end

  test "every exemption is still actually handled (no stale exemptions)" do
    handled = MapSet.new(handled_action_strings())

    stale = Enum.reject(@unwired_exemptions, &MapSet.member?(handled, &1))

    assert stale == [],
           "Exempted action(s) no longer have a handle_dispatch/3 clause: " <>
             "#{inspect(stale)}. Remove them from @unwired_exemptions."
  end

  test "no exempted action is dispatched by the React client via world:dispatch" do
    sources = frontend_sources()
    assert sources != [], "frontend source scan found no files — wrong assets/src path?"

    blob = sources |> Enum.map(&File.read!/1) |> Enum.join("\n")

    wired =
      Enum.filter(@unwired_exemptions, fn action -> String.contains?(blob, ~s("#{action}")) end)

    assert wired == [],
           "Exempted action(s) ARE now dispatched by the frontend: #{inspect(wired)}. " <>
             "They are no longer 'unwired' — move them from @unwired_exemptions into " <>
             "DispatchContract.actions(:conversation) so world:dispatch actually routes them."
  end

  # ---- source-AST enumeration of handle_dispatch/3 action strings ----------

  defp handled_action_strings do
    {:ok, src} = File.read(conversation_actions_source())
    {:ok, ast} = Code.string_to_quoted(src)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, _body]} = node, acc -> {node, collect_action(head, acc)}
        node, acc -> {node, acc}
      end)

    acc |> Enum.uniq() |> Enum.sort()
  end

  # A guarded clause head is wrapped in `:when`; an unguarded one is the raw call.
  defp collect_action({:when, _, [call, _guard]}, acc), do: collect_action(call, acc)

  defp collect_action({:handle_dispatch, _, [_socket, action, _args]}, acc)
       when is_binary(action),
       do: [action | acc]

  defp collect_action(_other, acc), do: acc

  defp conversation_actions_source do
    path = to_string(Ezagent.World.ConversationActions.module_info(:compile)[:source])

    if File.exists?(path) do
      path
    else
      Path.expand("../../../lib/ezagent/world/conversation_actions.ex", __DIR__)
    end
  end

  defp frontend_sources do
    Path.wildcard(Path.expand("../../../assets/src/**/*.{ts,tsx}", __DIR__))
  end
end
