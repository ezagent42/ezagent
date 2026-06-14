defmodule EzagentCore.Invariants.ReceiverKindPatternTest do
  @moduledoc """
  Phase 5 drift defense — Layer 2 invariant test.

  Per memory `feedback_plugin_external_integration_is_receiver_kind` and
  `docs/notes/plugin-receiver-kind-contract.md`: any plugin that sends
  ESR messages OUT to an external system MUST model the external
  destination as either (a) a Receiver Kind (URI scheme + Behavior
  with `:receive` action — pre-PR-144 shape) OR (b) a Behavior
  registered on an existing core Kind (Session for per-room mirrors,
  User for per-user channels) with side-table metadata
  (PR-144 SPEC v2 §5.8 shape). Both pass through `Ezagent.Invocation.dispatch/1`
  so CapBAC + audit + idempotency apply. Neither shape may
  PubSub-subscribe to a session/chat topic and write externally in a
  `handle_info` — that bypasses dispatch entirely.

  This test grep-walks all plugin source for the forbidden pattern:
  - `Phoenix.PubSub.subscribe` referencing `chat_message` or session
    events topic
  - AND in the same file: HTTP/file write APIs (`:httpc.request`,
    `HTTPoison.`, `Req.`, `Tesla.`, `File.write`, `:file.write`, etc)

  If both signals appear in the same plugin file, flag it for review
  unless the file has an explicit `# receiver-kind-exempt: <reason>`
  comment (escape hatch for legitimate cases like AuditWriter that
  writes the OWN audit log).

  ## How to fix a failing test

  If your plugin gets flagged:
  1. Read `docs/notes/plugin-receiver-kind-contract.md`
  2. Refactor: external destination becomes a Kind with `:receive`
     action; routing rule binds it
  3. Delete the PubSub subscriber

  Reference impl: `apps/ezagent_plugin_feishu/` —
  PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §9)
  reshaped this into the generic ExternalMirror Adapter+Binding pair
  (`EzagentPluginFeishu.FeishuAdapter` + `FeishuChatBinding`); the
  per-binding Worker Kind is dispatched-to via
  `Ezagent.Invocation.dispatch/1` per P14, so the receiver-kind
  invariant is preserved structurally without an explicit plugin
  Receiver Kind.
  """
  use ExUnit.Case, async: true

  @plugin_dirs ~w(
    apps/ezagent_domain_session
    apps/ezagent_plugin_cc_bridge_v1_prototype
    apps/ezagent_plugin_cc
    apps/ezagent_plugin_cc
    apps/ezagent_plugin_echo
    apps/ezagent_plugin_feishu
  )

  @subscribe_signals ~w(
    Phoenix.PubSub.subscribe
  )

  @forbidden_topic_substrings ~w(
    chat_message
    session_events_topic
    esr:session:
  )

  @external_write_signals ~w(
    :httpc.request
    HTTPoison.
    Req.post
    Req.put
    Req.patch
    Tesla.post
    File.write
    File.write!
    File.cp
    File.cp!
    :file.write
  )

  @exempt_marker "receiver-kind-exempt:"

  test "no plugin handle_info subscribes to chat PubSub AND writes externally" do
    offenders =
      @plugin_dirs
      |> Enum.flat_map(&plugin_files/1)
      |> Enum.filter(&forbidden_pattern_present?/1)
      |> Enum.reject(&exempt?/1)

    assert offenders == [], """
    The following plugin file(s) appear to combine `Phoenix.PubSub.subscribe`
    on a chat/session topic with an external write API in the same file
    (HTTP / file write). This is the forbidden side-channel pattern per
    `docs/notes/plugin-receiver-kind-contract.md` — external integrations
    must be Receiver Kinds.

    #{Enum.map_join(offenders, "\n", &("  - " <> &1))}

    Either refactor to Receiver Kind shape, or add the line:

        # #{@exempt_marker} <one-line reason>

    near the top of the file to mark it as a legitimate exception
    (e.g. observer that writes its own audit log, not external).
    """
  end

  defp plugin_files(dir) do
    repo_root = repo_root!()
    abs = Path.join(repo_root, dir)

    if File.dir?(abs) do
      [abs <> "/lib/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard/1)
    else
      []
    end
  end

  defp forbidden_pattern_present?(path) do
    src = File.read!(path)

    has_subscribe? =
      Enum.any?(@subscribe_signals, &String.contains?(src, &1)) and
        Enum.any?(@forbidden_topic_substrings, &String.contains?(src, &1))

    has_external_write? = Enum.any?(@external_write_signals, &String.contains?(src, &1))

    has_subscribe? and has_external_write?
  end

  defp exempt?(path) do
    case File.read(path) do
      {:ok, src} -> String.contains?(src, @exempt_marker)
      _ -> false
    end
  end

  defp repo_root! do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the
          # umbrella root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    String.trim(out)
  end
end
