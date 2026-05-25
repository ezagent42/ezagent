defmodule Ezagent.Cap do
  @moduledoc """
  Cap-string matcher — the new representation of capability authority.

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` §5.2 +
  §5.4.

  Caps are PLAIN STRINGS (not `%Ezagent.Capability{}` structs). The
  format is:

      cap_string  := allowlisted_special | scoped_cap
      allowlisted_special := "*" | "cross-workspace:*"
      scoped_cap  := authority instance_suffix?
      authority   := kind "." behavior ( "." action | ".*" )?
      instance_suffix := "@" instance_uri
      kind        := atom_string | "*"
      behavior    := atom_string | "*"
      action      := atom_string

  ## Examples

      "*"                                              # admin all (allowlisted)
      "cross-workspace:*"                              # cross-workspace bypass
      "session.*"                                      # all session actions
      "session.chat"                                   # all session.chat.* actions
      "session.chat.send"                              # one specific action
      "session.chat@session://default/team/main"       # all chat actions on one session
      "session.chat.send@session://default/team/main"  # one action on one session

  ## Matching semantics (`matches?/2`)

  The HELD cap matches the NEEDED cap when the held cap's authority
  is at least as broad as the needed cap's. `*` is a wildcard at each
  segment position; absent action means "all actions"; absent
  instance suffix means "any instance".

  Examples (held → needed):

      matches?("*", _needed)                                   # true (admin)
      matches?("session.chat", "session.chat.send")            # true (action-level held)
      matches?("session.chat.*", "session.chat.send")          # true (glob)
      matches?("session.*", "session.chat.send")               # true (behavior-glob)
      matches?("*.chat.send", "session.chat.send")             # true (kind-glob)
      matches?("session.chat.send", "session.chat.send")       # true (exact)
      matches?("session.chat.send", "session.chat.join")       # false (action differs)
      matches?("session.chat@A", "session.chat.send@A")        # true (same instance)
      matches?("session.chat@A", "session.chat.send@B")        # false (different instance)
      matches?("session.chat", "session.chat.send@A")          # true (no held instance constraint)
      matches?("session.chat.send@A", "session.chat.send")     # false (held requires instance A)

  The matcher is pure + has no external dependencies; ~80 LOC.
  """

  @typedoc "A cap string. The runtime canonical representation of authority."
  @type t :: String.t()

  @doc """
  Does HELD authorize NEEDED?

  Both arguments are cap strings. Returns true when held is at least
  as broad as needed.
  """
  @spec matches?(t(), t()) :: boolean()
  def matches?(held, needed) when is_binary(held) and is_binary(needed) do
    # Allowlisted special: "*" matches anything.
    cond do
      held == "*" ->
        true

      held == needed ->
        true

      true ->
        do_match(parse(held), parse(needed))
    end
  end

  # Compare parsed shapes. A `held` cap is `{kind, behavior, action, instance}`
  # where each segment is `:wildcard` or a literal binary.
  defp do_match(
         {h_kind, h_beh, h_act, h_inst},
         {n_kind, n_beh, n_act, n_inst}
       ) do
    segment_match?(h_kind, n_kind) and
      segment_match?(h_beh, n_beh) and
      action_match?(h_act, n_act) and
      instance_match?(h_inst, n_inst)
  end

  # Kind / behavior segment: wildcard or exact match.
  defp segment_match?(:wildcard, _), do: true
  defp segment_match?(same, same), do: true
  defp segment_match?(_, _), do: false

  # Action segment: held's `:absent` (no action specified — behavior-level
  # cap) matches any needed action. `:wildcard` (explicit `*`) likewise.
  # Otherwise exact match.
  defp action_match?(:absent, _), do: true
  defp action_match?(:wildcard, _), do: true
  defp action_match?(same, same), do: true
  defp action_match?(_, _), do: false

  # Instance: held's `:absent` (no `@suffix`) matches any needed instance
  # (the cap is not instance-scoped). If held has an instance, it must
  # equal the needed instance exactly.
  defp instance_match?(:absent, _), do: true
  defp instance_match?(same, same), do: true
  defp instance_match?(_, _), do: false

  # Parse a cap string into `{kind, behavior, action, instance}`. Each
  # segment is either `:wildcard`, `:absent`, or a literal binary.
  #
  # NB: special cases for `"*"` and `"cross-workspace:*"` are handled by
  # the matches? top-level (so we don't go through parse()).
  defp parse("cross-workspace:*"),
    do: {{:special, "cross-workspace"}, :wildcard, :wildcard, :absent}

  defp parse(s) when is_binary(s) do
    {body, instance} = split_instance(s)

    parts =
      body
      |> String.split(".", parts: 3)
      |> Enum.map(&segment/1)

    {kind, behavior, action} =
      case parts do
        [k, b, a] -> {k, b, a}
        [k, b] -> {k, b, :absent}
        [k] -> {k, :absent, :absent}
        [] -> {:absent, :absent, :absent}
      end

    {kind, behavior, action, instance}
  end

  defp segment("*"), do: :wildcard
  defp segment(literal), do: literal

  defp split_instance(s) do
    case String.split(s, "@", parts: 2) do
      [body, instance_str] -> {body, instance_str}
      [body] -> {body, :absent}
    end
  end

  @doc """
  Does the entity's caps list grant the needed cap?

  Default impl behind `Ezagent.Kind.holds_cap?/2` (SPEC §5.2). Walks
  the cap list and checks each held cap via `matches?/2`.
  """
  @spec any_match?([t()], t()) :: boolean()
  def any_match?(caps, needed) when is_list(caps) and is_binary(needed) do
    Enum.any?(caps, &matches?(&1, needed))
  end

  def any_match?(_, _), do: false
end
