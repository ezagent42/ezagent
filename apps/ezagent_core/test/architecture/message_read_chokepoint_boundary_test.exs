defmodule EzagentCore.MessageReadChokepointBoundaryTest do
  @moduledoc """
  Read-plane-authz PR-1 drift gate (Pillar B) — the message plane, NARROW slice.

  A principal-facing / presenter-tier module MUST NOT read the conversation
  message store directly: every conversation message read routes through the
  `Ezagent.Socialware.SessionReads` chokepoint (which authorizes the caller
  FIRST). A direct `MessageStore.<windowed-read>` OR a raw `Repo` query over the
  `Message` schema added to the presenter tier → this test RED, so a new bypass
  cannot merge and re-open the deep-link info-disclosure.

  Scope is deliberately narrow (this PR's slice only): the MESSAGE plane in the
  world/web/socialware presenter tier. It does NOT gate the members / delivery /
  surface / list / recipe / filesystem planes — those tighten in PR-2..PR-5 as
  their chokepoints land. The still-unmigrated feed + uploads readers are
  explicitly allowlisted until then; `session_reads.ex` is the authorized reader.

  Completeness (Pillar B): the allowlist is the ONLY legal set — the red build
  is the exhaustive worklist for this plane, not a hand-maintained census.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The presenter / principal-facing read tier for the message plane.
  @scan_dirs [
    "apps/ezagent_plugin_world/lib",
    "apps/ezagent_web/lib",
    "apps/ezagent_domain_socialware/lib"
  ]

  # Windowed conversation-content reads on `Ezagent.MessageStore` — the bypass
  # vector this PR migrates onto `SessionReads`. (Non-content ops like `write`,
  # `by_id`, `sessions_for_message`, `mark_visibility`, `relabel_identity` are
  # not conversation reads and are out of scope.)
  @banned_message_store_reads ~w(
    recent_in_session
    recent_visible_in_session
    older_than
    older_visible_than
    chat_visible_recent
    committed_external_visible
    committed_external_visible_by_ids
    in_session_since
  )

  # Modules permitted to read the message store directly:
  #   * session_reads.ex     — THE chokepoint (the authorized reader / store owner-caller)
  #   * chat_feed.ex         — deferred to PR-2 (routes through SessionReads there)
  #   * external_feed.ex     — deferred to PR-2
  #   * uploads_controller.ex — deferred to PR-3 (attachment plane)
  @allowlisted_basenames ~w(
    session_reads.ex
    chat_feed.ex
    external_feed.ex
    uploads_controller.ex
  )

  # A raw Ecto query over the Message schema — only `MessageStore` may build one.
  @message_repo_query ~r/\bfrom\(\s*\w+\s+in\s+(Ezagent\.)?Message\b/

  test "no presenter-tier module reads the conversation message store outside SessionReads" do
    offenders =
      @scan_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**/*.ex"])))
      |> Enum.reject(&(Path.basename(&1) in @allowlisted_basenames))
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [],
           """
           Read-plane-authz message gate: a presenter/web/socialware module reads the
           conversation message store DIRECTLY. Route the read through
           `Ezagent.Socialware.SessionReads.messages/4` (which authorizes the caller
           first) instead of touching `MessageStore`/`Repo`. Offenders:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "the SessionReads chokepoint IS in the allowlist (the door exists)" do
    # Guards against the allowlist silently drifting to exclude the one module
    # that legitimately reads the store — which would make the gate vacuous.
    assert "session_reads.ex" in @allowlisted_basenames

    assert File.regular?(
             Path.join(
               @repo_root,
               "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex"
             )
           )
  end

  defp offenders_in_file(path) do
    rel = Path.relative_to(path, @repo_root)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      if code_line?(line) and violates?(line) do
        ["#{rel}:#{lineno}: #{String.trim(line)}"]
      else
        []
      end
    end)
  end

  # Skip comment lines and backtick-quoted prose (moduledoc symbol mentions).
  defp code_line?(line) do
    trimmed = String.trim(line)
    not (trimmed == "" or String.starts_with?(trimmed, "#"))
  end

  defp violates?(line) do
    banned_store_read?(line) or Regex.match?(@message_repo_query, line)
  end

  defp banned_store_read?(line) do
    # Only a REAL call `MessageStore.<fn>(` — not a backtick doc reference.
    Enum.any?(@banned_message_store_reads, fn fun ->
      String.contains?(line, "MessageStore.#{fun}(") and
        not String.contains?(line, "`MessageStore.#{fun}")
    end)
  end
end
