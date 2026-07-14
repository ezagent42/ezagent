defmodule Ezagent.Invariants.CapIssueChokepointBoundaryTest do
  @moduledoc """
  The chokepoint gate's own boundary — as a TEST, not a comment.

  `cap_issue_chokepoint_test.exs` leg 3b enumerates every call site of a
  `users.caps_json` writer. It has been evaded three times:

    1. it scanned only `Users.create/3,4`      → `create_read_only/2` walked past
    2. it scanned only `apps/**/*.ex`          → `scripts/*.exs` walked past
    3. it matched only a bare remote call      → a PIPE walked past, and so did
                                                 alias / import / @attr / apply /
                                                 capture

  Each time the comment said "now it catches the next bypass." Each time it did
  not. A comment cannot hold a boundary. So the boundary lives here, and it is
  measured on every run:

    * the seven spellings below MUST be caught
    * `Module.concat/1` — the module resolved at RUNTIME — MUST NOT be, because
      no source scan can see it. That is pinned deliberately. If someone teaches
      the scanner to see it, this test fails and forces them to come back and
      update what the gate CLAIMS.

  ## Why the blind spot is not patchable

  The property we want is about RUNTIME: "every cap that reaches
  `users.caps_json` passed `Ezagent.Cap.issue/3`". A source scan proves
  something weaker — "every STATICALLY RESOLVABLE call is enumerated" — and the
  gap between them is not closable by a better scanner.

  Closing it for real means making the property structural: `Cap.issue/3`
  records what it issued, `Ezagent.Users` refuses a cap that was never issued.
  Then the spelling of the call stops mattering entirely. That changes core and
  a public API contract, so it is a decision, not a test fix — see
  `docs/notes/2026-07-14-cap-issue-structural-enforcement.md`.
  """
  use ExUnit.Case, async: true

  @scanner "apps/ezagent_core/test/invariants/cap_issue_chokepoint_test.exs"

  # Each fixture is a module that reaches a `caps_json` writer. `caught?` runs
  # the scanner's own detector over it.
  @seen [
    {"plain remote call", "def m(u, p, c), do: Ezagent.Users.create(u, p, c)"},
    {"pipe", "def m(u, p, c), do: u |> Ezagent.Users.create(p, c)"},
    {"alias with :as",
     """
     alias Ezagent.Users, as: U
     def m(u, p, c), do: u |> U.create(p, c)
     """},
    {"multi-alias",
     """
     alias Ezagent.{Users, Capability}
     def m(u, p, c), do: Users.create(u, p, c)
     def x, do: Capability
     """},
    {"import -> bare local call",
     """
     import Ezagent.Users, only: [create: 3]
     def m(u, p, c), do: create(u, p, c)
     """},
    {"module attribute",
     """
     @users Ezagent.Users
     def m(u, p, c), do: @users.create(u, p, c)
     """},
    {"apply/3", "def m(u, p, c), do: apply(Ezagent.Users, :create, [u, p, c])"},
    {"capture", "def m, do: &Ezagent.Users.create_read_only/2"}
  ]

  @blind [
    {"module atom built at RUNTIME",
     """
     def m(u, p, c) do
       mod = Module.concat([:Ezagent, :Users])
       mod.create(u, p, c)
     end
     """}
  ]

  describe "the gate sees these — every one verified, none assumed" do
    for {name, body} <- @seen do
      test name do
        assert caught?(unquote(body)),
               """
               A `users.caps_json` writer spelled as "#{unquote(name)}" is INVISIBLE to
               the chokepoint gate. Anyone adding an unissued cap this way ships green.

               Teach `collect_site/2` in #{@scanner} to see it.
               """
      end
    end
  end

  describe "the gate is BLIND to these — pinned on purpose" do
    for {name, body} <- @blind do
      test name do
        refute caught?(unquote(body)),
               """
               The scanner now sees "#{unquote(name)}".

               That is a real improvement — but the gate's stated claim says it does
               NOT, and a claim that undersells is still a wrong claim. Go update:

                 * the boundary comment in #{@scanner}
                 * the moduledoc of this file
                 * anything that repeats "statically resolvable"

               Then move this fixture into `@seen`.
               """
      end
    end
  end

  # ---------------------------------------------------------------
  # Run the SCANNER ITSELF over a fixture. This deliberately reuses the
  # production detector rather than reimplementing it — a boundary test that
  # tested its own copy of the logic would prove nothing.
  # ---------------------------------------------------------------
  defp caught?(body) do
    src = "defmodule Fixture do\n  @moduledoc false\n#{body}\nend\n"

    path =
      Path.join(System.tmp_dir!(), "cap_gate_fixture_#{System.unique_integer([:positive])}.ex")

    File.write!(path, src)

    try do
      EzagentCore.CapsJsonScanner.users_create_cap_args(path) != []
    after
      File.rm(path)
    end
  end
end
