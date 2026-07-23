defmodule Ezagent.Domain.Pty.Server.FormatStatusRedactionTest do
  @moduledoc """
  Regression for the `cmd_env` secret-leak fix (issue #1455 / PR #1513).

  `cmd_env` carries secrets by design — vendor API keys and internal
  tokens (`ANTHROPIC_AUTH_TOKEN`, `EZAGENT_AGENT_TOKEN`, …) the cc plugin
  passes to the spawned `claude`. `format_status/2` is the OTP GenServer
  chokepoint that runs BEFORE the state reaches a crash report / the
  error logger / `:sys.get_status` output. The fix scrubs EVERY `cmd_env`
  value to `"[REDACTED]"` there (keeping key names for debuggability), so
  a crash never spills the tokens into logs.

  This test pins BOTH directions so a future refactor cannot silently
  re-introduce the leak:

    * every `cmd_env` value in the returned status is `"[REDACTED]"`, and
      the raw secret bytes appear NOWHERE in the inspected status (guards
      against a PARTIAL redaction regression), AND
    * the key NAMES survive (we keep visibility into WHICH env vars were
      set).

  It also covers the empty / absent `cmd_env` clauses (`map_size == 0`
  and the non-map/`nil` case) — those must pass through untouched, never
  crash the callback.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  # Fake, secret-LOOKING values. If any of these strings survives into the
  # status the callback returns, redaction leaked.
  @anthropic_secret "sk-secret-abc"
  @agent_token_secret "tok-xyz"

  @secret_cmd_env %{
    "ANTHROPIC_AUTH_TOKEN" => @anthropic_secret,
    "EZAGENT_AGENT_TOKEN" => @agent_token_secret,
    "PATH" => "/usr/bin"
  }

  # A representative process dictionary — format_status/2's first list
  # element. We assert it flows through the callback UNCHANGED (the
  # callback must scrub only the state slot, not mangle the pdict slot).
  @pdict [{:some_pdict_key, :some_pdict_value}]

  defp state(cmd_env) do
    %PtyServer{
      agent_uri: URI.new!("entity://team-alpha/agent/format_status_redaction_test"),
      cmd_env: cmd_env
    }
  end

  # Inspect with NO truncation — default `inspect/1` limits could hide a
  # leaked secret past the "..." cutoff and give us a false pass. The whole
  # point of the partial-redaction guard is to prove the bytes are gone
  # from the ENTIRE returned status, not just the part inspect chose to show.
  defp full_inspect(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  describe "format_status/2 redacts cmd_env secret values" do
    for status_kind <- [:normal, :terminate] do
      test "#{status_kind}: every cmd_env value is [REDACTED] and no secret bytes leak" do
        [returned_pdict, scrubbed] =
          PtyServer.format_status(unquote(status_kind), [@pdict, state(@secret_cmd_env)])

        # The pdict slot passes through untouched — the callback scrubs the
        # state, it does not rewrite the process dictionary.
        assert returned_pdict == @pdict

        # Every value is blanket-replaced; not one original value survives.
        assert Enum.all?(scrubbed.cmd_env, fn {_k, v} -> v == "[REDACTED]" end),
               "expected every cmd_env value to be \"[REDACTED]\", got: " <>
                 inspect(scrubbed.cmd_env)

        # Partial-redaction guard: the raw secret bytes must appear NOWHERE
        # in the full returned status (state struct + pdict), not merely be
        # absent from cmd_env's values.
        rendered = full_inspect([returned_pdict, scrubbed])
        refute String.contains?(rendered, @anthropic_secret)
        refute String.contains?(rendered, @agent_token_secret)
      end

      test "#{status_kind}: cmd_env key NAMES are preserved" do
        [_pdict, scrubbed] =
          PtyServer.format_status(unquote(status_kind), [@pdict, state(@secret_cmd_env)])

        # Every key we set is still present (same set, none dropped/renamed).
        assert Map.keys(scrubbed.cmd_env) |> Enum.sort() ==
                 Map.keys(@secret_cmd_env) |> Enum.sort()

        # And the names are visible in the rendered status for debugging.
        rendered = full_inspect(scrubbed)
        assert String.contains?(rendered, "ANTHROPIC_AUTH_TOKEN")
        assert String.contains?(rendered, "EZAGENT_AGENT_TOKEN")
        assert String.contains?(rendered, "PATH")
      end
    end
  end

  describe "format_status/2 with empty / absent cmd_env" do
    test ":normal with an empty cmd_env map does not crash and passes through" do
      [returned_pdict, scrubbed] =
        PtyServer.format_status(:normal, [@pdict, state(%{})])

      assert returned_pdict == @pdict
      assert scrubbed.cmd_env == %{}
    end

    test ":terminate with a nil cmd_env does not crash and passes through" do
      [returned_pdict, scrubbed] =
        PtyServer.format_status(:terminate, [@pdict, state(nil)])

      assert returned_pdict == @pdict
      assert scrubbed.cmd_env == nil
    end
  end
end
