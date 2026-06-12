defmodule EzagentCore.Invariants.SessionSendIsSolePublicVerbTest do
  @moduledoc """
  PR-1 (im/session/agent decomposition) — MED-1 cross-PR gate.

  `session.send` is the SINGLE public verb every external caller uses to
  post into a Session; `chat.send` is demoted to a session-INTERNAL
  fan-out verb (`Ezagent.Behavior.Chat.handle_send/2`, reached ONLY via
  `Ezagent.Behavior.Session`'s in-process delegation).

  This gate asserts that NO production source file reintroduces an
  EXTERNAL `chat.send` dispatch — neither

    * `Ezagent.URI.with_action(_, :chat, :send)` (the dispatch-target
      builder), nor
    * the `?action=chat.send` query-string literal in a dispatch target,

  ANYWHERE under `apps/**/lib/` except the session-domain internals that
  legitimately name the demoted verb (the `Ezagent.Behavior.Session`
  module that documents the demotion, and `Ezagent.Behavior.Chat` /
  `Ezagent.Behavior.Chat.*` which OWN the internal fan-out). A
  re-introduced external caller would silently re-open the public
  `chat.send` surface the decomposition closed, splitting the public
  entry across two verbs.

  ## Scope

  Scans every `.ex` / `.exs` under `apps/**/lib/` (PRODUCTION source — a
  "caller" is production code; URI-machinery TEST fixtures that use
  `chat.send` as a generic parser example are out of scope). Excludes
  the small allowlist of session-domain internals below.

  Failure mode: prints the offending file + line so the gating PR can be
  fixed (migrate the caller to `?action=session.send` /
  `with_action(_, :session, :send)`) before merge.
  """
  use ExUnit.Case, async: true

  # Session-domain internals allowed to NAME the demoted `chat.send` verb:
  # - Behavior.Session: documents the demotion + delegates to the internal
  #   Chat fan-out (its moduledoc references `chat.send` for explanation).
  # - Behavior.Chat (+ Chat.* helpers e.g. Chat.Delivery): OWN the internal
  #   fan-out logic.
  @allowed_suffixes [
    "apps/ezagent_domain_instance_message/lib/ezagent/behavior/session.ex",
    "apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex"
  ]

  # The dispatch-builder form: `with_action(<x>, :chat, :send)` (whitespace
  # tolerant). This is unambiguous — it ALWAYS builds a chat.send dispatch
  # target; a generic URI-parser fixture never uses it.
  @with_action_re ~r/with_action\([^)]*,\s*:chat,\s*:send\)/

  # The query-string literal in a dispatch target.
  @action_literal "?action=chat.send"

  defp apps_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    Path.join(String.trim(out), "apps")
  end

  defp production_lib_files do
    apps_root()
    |> Path.join("*/lib/**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(fn p -> Enum.any?(@allowed_suffixes, &String.ends_with?(p, &1)) end)
  end

  defp offenders_for(needle_check) do
    Enum.flat_map(production_lib_files(), fn p ->
      case File.read(p) do
        {:ok, body} ->
          body
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, idx} ->
            if needle_check.(line), do: [{p, idx, String.trim(line)}], else: []
          end)

        _ ->
          []
      end
    end)
  end

  test "no production caller builds a chat.send dispatch target via with_action(_, :chat, :send)" do
    offenders = offenders_for(fn line -> Regex.match?(@with_action_re, line) end)

    assert offenders == [],
           """
           External chat.send caller(s) reintroduced via
           `with_action(_, :chat, :send)`:

           #{format(offenders)}

           PR-1 (MED-1): session.send is the SINGLE public Session post
           verb; chat.send is session-internal. Migrate the caller to
           `Ezagent.URI.with_action(<session_uri>, :session, :send)`
           (the action atom stays :send; only the public verb spelling
           changes). The fan-out itself lives in
           Ezagent.Behavior.Chat.handle_send/2, reached ONLY via
           Ezagent.Behavior.Session.
           """
  end

  test "no production caller targets the ?action=chat.send literal" do
    offenders = offenders_for(fn line -> String.contains?(line, @action_literal) end)

    assert offenders == [],
           """
           External chat.send caller(s) reintroduced via the
           `?action=chat.send` literal:

           #{format(offenders)}

           PR-1 (MED-1): use `?action=session.send` for the public verb.
           chat.send is no longer publicly dispatchable (its
           {Session/SocialwareSession, :send} registration is owned by
           Ezagent.Behavior.Session).
           """
  end

  defp format(offenders),
    do: Enum.map_join(offenders, "\n", fn {p, idx, line} -> "  #{p}:#{idx}  #{line}" end)
end
