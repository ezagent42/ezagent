Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.BusinessAdminCheckTest do
  @moduledoc """
  Admin/business decoupling gate (2026-07-09).

  `Ezagent.Identity.admin?/1` recognizes ONLY the genesis bootstrap singleton
  (`Ezagent.Entity.User.admin_uri/0`) — a CONFIG/bootstrap authority predicate,
  not a business superuser check. Business paths (session listing, chat,
  messages, conversation, uploads) authorize via membership + caps at the
  dispatch chokepoint; the `business_context_admin_checks` counter flags any
  identity-admin predicate call (`Identity.admin?` / `AdminAuthority.admin?`)
  or direct admin-URI comparison outside the sanctioned CONFIG/bootstrap
  allowlist (`@business_admin_check_sanctioned_files` in the scanner).

  Three halves:

    * the target-zero assertion over the real lib tree, with the violating
      sites in the failure message (the worklist),
    * a teeth check — the matcher must find the SANCTIONED config sites on the
      real tree pre-allowlist (proves the regex is not vacuously green), and
    * positive + negative fixtures over the pure
      `count_business_admin_checks_in_source/1` line classifier.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "no business-context admin checks in lib code (membership + caps govern business paths)" do
    violations = Scan.business_context_admin_check_violations()

    assert violations == [],
           """
           Business-context admin check(s) detected — business paths must authorize
           via membership + caps, never via an identity-admin predicate:

           #{Enum.map_join(violations, "\n", fn {file, line, text} -> "  #{file}:#{line} — #{text}" end)}

           Either delete the admin branch (membership/caps already govern) or, for a
           genuinely-new CONFIG/bootstrap surface, add the file to
           `@business_admin_check_sanctioned_files` in ezagent.arch.scan with a reason.
           """
  end

  test "TEETH: the matcher finds the sanctioned CONFIG sites pre-allowlist on the real tree" do
    offender_files =
      Scan.business_admin_check_offender_hits()
      |> Enum.map(fn {file, _line, _text} -> file end)

    # The admin-console mount gate, the genesis predicate definition, and the
    # genesis self-mint comparison are real, permanent hits — if the regexes
    # rot, this fails before the target-zero assertion goes vacuously green.
    assert "apps/ezagent_web/lib/ezagent_web/live_auth.ex" in offender_files
    assert "apps/ezagent_domain_identity/lib/ezagent/identity.ex" in offender_files
    assert "apps/ezagent_domain_identity/lib/ezagent/entity/user.ex" in offender_files
  end

  describe "line-classifier fixtures (count_business_admin_checks_in_source/1)" do
    test "POSITIVE: a qualified Identity.admin? call is flagged" do
      source = """
      defmodule Demo.Listing do
        def visible?(caller_uri) do
          Ezagent.Identity.admin?(caller_uri) or member?(caller_uri)
        end
      end
      """

      assert Scan.count_business_admin_checks_in_source(source) == 1
    end

    test "POSITIVE: an aliased AdminAuthority.admin? call is flagged" do
      source = """
      defmodule Demo.Chat do
        alias Ezagent.Identity.AdminAuthority

        def can_post?(caller, caps), do: AdminAuthority.admin?(caller, caps)
      end
      """

      assert Scan.count_business_admin_checks_in_source(source) == 1
    end

    test "POSITIVE: a hand-rolled admin-URI comparison is flagged (p13 shape)" do
      source = """
      defmodule Demo.Uploads do
        def operator?(uri), do: URI.to_string(uri) == URI.to_string(User.admin_uri())
        def operator2?(uri), do: same_uri?(uri, Ezagent.Entity.User.admin_uri())
      end
      """

      assert Scan.count_business_admin_checks_in_source(source) == 2
    end

    test "NEGATIVE: a caps-local admin? helper (cap check, not identity) is NOT flagged" do
      source = """
      defmodule Demo.Kanban do
        def owner_or_admin?(ctx, node), do: admin?(ctx) or node.owner == caller_str(ctx)
        defp admin?(ctx), do: Shared.admin?(ctx)
      end
      """

      assert Scan.count_business_admin_checks_in_source(source) == 0
    end

    test "NEGATIVE: admin_uri as a VALUE (granter/caller seed) is NOT flagged" do
      source = """
      defmodule Demo.Seed do
        def granter, do: Ezagent.Entity.User.admin_uri()
        def ctx, do: %{caller: Ezagent.Entity.User.admin_uri(), caps: MapSet.new()}
      end
      """

      assert Scan.count_business_admin_checks_in_source(source) == 0
    end

    test "NEGATIVE: comment lines and `# arch-allow:` suppression are NOT flagged" do
      source = """
      defmodule Demo.Docs do
        # checked via Ezagent.Identity.admin?(caller) in the console gate
        def gate(uri), do: Ezagent.Identity.admin?(uri) # arch-allow: fixture
      end
      """

      assert Scan.count_business_admin_checks_in_source(source) == 0
    end
  end
end
