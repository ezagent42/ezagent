defmodule EzagentPluginGitWorkflow.BlockerTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.Blocker

  @moduletag :blocker

  # Every atom member of `Ezagent.DomainGit.Error.t()`
  # (apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex lines 5-22).
  # Enumerated literally rather than read from the module because `t()` is a
  # TYPE — there is nothing to read at runtime — and because this plugin must
  # not grow a dependency on the GitHub owner's error vocabulary beyond
  # consuming it. THIS is the test that catches a future domain_git addition:
  # a new member added there without a mapping here lands on :internal_error.
  @domain_git_errors [
    :provider_account_not_connected,
    :credential_backend_unavailable,
    :repository_not_found,
    :repository_read_denied,
    :repository_write_denied,
    :private_checkout_not_supported,
    :base_ref_not_found,
    :base_sha_mismatch,
    :invalid_ref,
    :invalid_file_change,
    :change_limit_exceeded,
    :change_request_conflict,
    :checks_unavailable,
    :provider_unavailable,
    :authentication_rejected,
    :installation_scope_mismatch,
    :head_ref_conflict,
    :provider_rate_limited
  ]

  # `Ezagent.Workspace.TaskWorkspace.ChangeCollector`'s moduledoc documents
  # seven error codes as its closed returned set; `:invalid_change_request`
  # comes from its fallback `collect(_request)` clause, which that list omits.
  # Enumerated literally: this plugin does not depend on
  # :ezagent_domain_workspace and must not start to for a test.
  @change_collector_errors [
    :workspace_not_ready,
    :workspace_identity_mismatch,
    :no_changes_collected,
    :unsupported_workspace_change,
    :change_limit_exceeded,
    :workspace_read_failed,
    :invalid_change_limits_config,
    :invalid_change_request
  ]

  @seam_errors [:authorization_unavailable, :not_authorized]

  describe "the vocabulary is total" do
    test "every Ezagent.DomainGit.Error atom member maps to a real code, not :internal_error" do
      assert length(@domain_git_errors) == 18

      for error <- @domain_git_errors do
        code = Blocker.from_error(error)

        refute code == :internal_error,
               "#{inspect(error)} (Ezagent.DomainGit.Error.t()) has no mapping"

        assert code in Blocker.codes()
      end
    end

    test "the {:provider_request_failed, _, _} tuple member maps by status class" do
      assert Blocker.from_error({:provider_request_failed, :create_ref, 401}) ==
               :provider_permission_denied

      assert Blocker.from_error({:provider_request_failed, :create_ref, 403}) ==
               :provider_permission_denied

      assert Blocker.from_error({:provider_request_failed, :create_ref, 429}) ==
               :provider_rate_limited

      assert Blocker.from_error({:provider_request_failed, :create_ref, 500}) ==
               :provider_unavailable

      assert Blocker.from_error({:provider_request_failed, :create_ref, 503}) ==
               :provider_unavailable

      assert Blocker.from_error({:provider_request_failed, :create_ref, 418}) ==
               :provider_unavailable
    end

    test "every ChangeCollector error maps to a real code, not :internal_error" do
      for error <- @change_collector_errors do
        code = Blocker.from_error(error)
        refute code == :internal_error, "#{inspect(error)} (ChangeCollector) has no mapping"
        assert code in Blocker.codes()
      end
    end

    test "the seam's two atoms pass through" do
      for error <- @seam_errors do
        assert Blocker.from_error(error) == error
      end
    end

    # VERIFIED against ChangeCollector's `read_one/6`: every reason other than
    # :change_limit_exceeded / :workspace_read_failed is normalized to
    # :unsupported_workspace_change before `collect/1` returns, so these four
    # never escape. They are therefore deliberately NOT in the vocabulary. If
    # this ever turns red because someone added a mapping, the collector's
    # "closed vocabulary" claim is what changed and needs re-checking.
    test "ChangeCollector's internal-only reasons are deliberately unmapped" do
      for internal <- [
            :binary_content,
            :executable_mode,
            :not_regular_file,
            :path_escapes_worktree
          ] do
        assert Blocker.from_error(internal) == :internal_error
      end
    end

    test "an unrecognised term becomes :internal_error and the term is dropped" do
      assert Blocker.from_error({:some_provider_thing, "Bearer ghp_secret"}) == :internal_error
      assert Blocker.from_error(%{body: "raw response"}) == :internal_error
      assert Blocker.from_error(:completely_unknown) == :internal_error
    end
  end

  describe "classify/1" do
    test "every code in the vocabulary has an answer" do
      for code <- Blocker.codes() do
        assert Blocker.classify(code) in [:retryable, :terminal_blocker],
               "#{inspect(code)} is unclassified"
      end
    end

    # Pins the vocabulary itself: adding or removing a code without saying so
    # fails here, so a vocabulary change cannot land unreviewed.
    test "the vocabulary is exactly the 15 design codes plus the 12 documented extensions" do
      assert Enum.sort(Blocker.codes()) == [
               :authorization_unavailable,
               :base_ref_not_found,
               :base_sha_mismatch,
               :change_limit_exceeded,
               :change_request_conflict,
               :checks_unavailable,
               :credential_backend_unavailable,
               :head_ref_conflict,
               :installation_scope_mismatch,
               :internal_error,
               :invalid_change_limits_config,
               :invalid_change_request,
               :invalid_file_change,
               :invalid_ref,
               :no_changes_collected,
               :not_authorized,
               :observation_incomplete,
               :private_checkout_not_supported,
               :provider_account_not_connected,
               :provider_permission_denied,
               :provider_rate_limited,
               :provider_unavailable,
               :repository_not_found,
               :unsupported_workspace_change,
               :workspace_identity_mismatch,
               :workspace_not_ready,
               :workspace_read_failed
             ]
    end

    test "raises for a code outside the vocabulary rather than defaulting" do
      assert_raise FunctionClauseError, fn -> Blocker.classify(:made_up_code) end
    end

    # §7.1's 2026-07-26 amendment calls this out precisely because the
    # intuitive reading ("retry and maybe the agent writes something") is
    # wrong: re-running the same generation yields the same empty diff.
    test "no_changes_collected is terminal, not retryable" do
      assert Blocker.classify(:no_changes_collected) == :terminal_blocker
    end

    test "internal_error is terminal — an unclassifiable failure is not a retry candidate" do
      assert Blocker.classify(:internal_error) == :terminal_blocker
    end

    test "provider rate limiting and unavailability are retryable" do
      assert Blocker.classify(:provider_rate_limited) == :retryable
      assert Blocker.classify(:provider_unavailable) == :retryable
    end

    test "deterministic conflicts are terminal" do
      assert Blocker.classify(:base_sha_mismatch) == :terminal_blocker
      assert Blocker.classify(:head_ref_conflict) == :terminal_blocker
      assert Blocker.classify(:change_request_conflict) == :terminal_blocker
      assert Blocker.classify(:not_authorized) == :terminal_blocker
    end
  end

  describe "present/4" do
    test "carries exactly the five fields §7.1 permits" do
      presented = Blocker.present(:provider_rate_limited, :create_change_request, 2, %{})

      assert presented |> Map.keys() |> Enum.sort() ==
               [:attempt, :code, :metadata, :retryable, :stage]
    end

    test "derives retryable from classify/1 rather than accepting it" do
      assert %{retryable: true} =
               Blocker.present(:provider_unavailable, :create_change_request, 1, %{})

      assert %{retryable: false} =
               Blocker.present(:no_changes_collected, :collect_workspace_changes, 1, %{})
    end

    # The provider-shaped `operation` atom must not survive into presentation.
    test "a provider_request_failed presentation contains no trace of the operation" do
      code = Blocker.from_error({:provider_request_failed, :create_ref, 403})

      # What makes the drop STRUCTURAL rather than a filtering step someone can
      # forget: `from_error/1` narrows to a bare vocabulary atom, so there is
      # nowhere for the operation to survive.
      assert is_atom(code) and code in Blocker.codes()

      presented = Blocker.present(code, :create_change_request, 1, %{status_class: 4})

      refute inspect(presented) =~ "create_ref"
      assert presented.code == :provider_permission_denied
    end

    test "rejects a binary metadata value" do
      assert_raise ArgumentError, fn ->
        Blocker.present(:provider_unavailable, :create_change_request, 1, %{body: "raw response"})
      end
    end

    test "the rejection message does not echo the offending value" do
      error =
        assert_raise ArgumentError, fn ->
          Blocker.present(:provider_unavailable, :create_change_request, 1, %{
            header: "Bearer ghp_secret"
          })
        end

      refute Exception.message(error) =~ "ghp_secret"
    end

    test "rejects a non-atom metadata key without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          Blocker.present(:provider_unavailable, :create_change_request, 1, %{
            "ghp_secret" => 1
          })
        end

      refute Exception.message(error) =~ "ghp_secret"
    end

    test "rejects metadata values that are neither integer, boolean nor atom" do
      for value <- [1.5, [1], {:a, 1}, %{a: 1}, self()] do
        assert_raise ArgumentError, fn ->
          Blocker.present(:provider_unavailable, :create_change_request, 1, %{v: value})
        end
      end
    end

    test "accepts integers, booleans and atoms" do
      assert %{metadata: %{retry_after_seconds: 30, truncated: true, source: :observation}} =
               Blocker.present(:provider_rate_limited, :list_checks, 3, %{
                 retry_after_seconds: 30,
                 truncated: true,
                 source: :observation
               })
    end

    test "refuses to present a code outside the vocabulary" do
      assert_raise FunctionClauseError, fn ->
        Blocker.present(:made_up_code, :create_change_request, 1, %{})
      end
    end
  end
end
