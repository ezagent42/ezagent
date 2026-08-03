defmodule EzagentPluginGitWorkflow.BlockerTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.Blocker

  @moduletag :blocker

  # Every atom member of `Ezagent.DomainGit.Error.t()`, READ OFF THE TYPESPEC.
  #
  # This list used to be a literal copy, carrying a comment that called itself
  # "the test that catches a future domain_git addition". It was not: a copy
  # does not change when the original does, so a member added to `error.ex`
  # sailed past it — measured, not assumed. The copy's stated reason ("`t()` is
  # a TYPE — there is nothing to read at runtime") is also untrue; typespecs
  # live in the BEAM chunk and `Code.Typespec.fetch_types/1` reads them, which
  # is what `domain_git_errors/0` below does.
  #
  # Reading the type is not a new dependency either: this app already depends
  # on `:ezagent_domain_git` (mix.exs) and consumes its values throughout. What
  # it must not do is EXTEND that vocabulary — see the moduledoc — and reading
  # is not extending.
  #
  # The tuple member `{:provider_request_failed, _, _}` is deliberately excluded
  # here; it has its own test below because it maps by status class, not by name.

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
      errors = domain_git_errors()

      # Proof the read WORKED, not a fingerprint of what it read. A silently
      # empty or garbage list would otherwise make the loop below vacuous and
      # this test would claim total coverage of nothing. The exact membership is
      # `plan_a_contract_test`'s job; duplicating it here would just be a second
      # copy to bump.
      assert length(errors) >= 18
      assert :provider_unavailable in errors
      assert :provider_response_unrecognized in errors

      for error <- errors do
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
    test "the vocabulary is exactly the 15 design codes plus the 14 documented extensions" do
      assert Enum.sort(Blocker.codes()) == [
               :authorization_unavailable,
               :base_ref_not_found,
               :base_sha_mismatch,
               :change_digest_mismatch,
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
               :provider_response_unrecognized,
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

    # The runtime list and the exported type are two statements of the same
    # vocabulary, and nothing else compares them: a code added to `@codes`
    # without a `code()` member leaves every runtime test green while Dialyzer
    # and the generated docs are told a returned value cannot occur. That is
    # exactly what happened when `:provider_response_unrecognized` was added.
    test "the exported code() type lists exactly the runtime vocabulary" do
      {:ok, specs} = Code.Typespec.fetch_types(Blocker)

      {:type, _, :union, members} =
        Enum.find_value(specs, fn
          {:type, {:code, definition, _args}} -> definition
          _ -> nil
        end)

      typed =
        Enum.map(members, fn
          {:atom, _, atom} -> atom
          other -> flunk("Blocker.code() gained a non-atom member: #{inspect(other)}")
        end)

      assert Enum.sort(typed) == Enum.sort(Blocker.codes())
    end

    # Asserted as a PAIR on purpose. Either half alone survives the failure this
    # guards against — the two codes being collapsed back into one — because
    # whichever code the collapse keeps still classifies the way its own
    # assertion expects. The pair is what says they are different questions:
    # "the provider gave us nothing" is worth re-asking, "the provider gave us
    # something we cannot read" is not.
    test "an unreadable response is terminal while an unavailable provider is retryable" do
      assert Blocker.classify(:provider_response_unrecognized) == :terminal_blocker
      assert Blocker.classify(:provider_unavailable) == :retryable
    end

    # §7.1's 2026-07-26 amendment calls this out precisely because the
    # intuitive reading ("retry and maybe the agent writes something") is
    # wrong: re-running the same generation yields the same empty diff.
    test "no_changes_collected is terminal, not retryable" do
      assert Blocker.classify(:no_changes_collected) == :terminal_blocker
    end

    # Slice P4c added it, so it needs its own reason on the record: a worktree
    # that moved between `changes_ready` and the commit re-reads the same moved
    # worktree on every retry, and committing a tree the run never recorded is
    # exactly what design §6.2's same-sha-on-retry guarantee forbids.
    test "change_digest_mismatch is terminal — the re-collected tree does not un-move" do
      assert Blocker.classify(:change_digest_mismatch) == :terminal_blocker
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

  # The atom members of `Ezagent.DomainGit.Error.t()`, read from the compiled
  # typespec so this file cannot drift from the domain type the way a restated
  # copy did.
  defp domain_git_errors do
    {:ok, specs} = Code.Typespec.fetch_types(Ezagent.DomainGit.Error)

    {:type, _, :union, members} =
      Enum.find_value(specs, fn
        {:type, {:t, definition, _args}} -> definition
        _ -> nil
      end)

    # Extraction is STRICT, not a filtering comprehension. `for {:atom, _, a} <-
    # members` would silently skip any member with another representation — an
    # alias, a nested union, a remote type — and this test would then report
    # total coverage of a vocabulary it had never seen, which is the exact
    # failure the literal copy this replaced already had once.
    Enum.flat_map(members, fn
      {:atom, _, atom} ->
        [atom]

      # The ONE non-atom member, matched by its tag rather than by "is a tuple".
      # `{:type, _, :tuple, _}` would wave through a future
      # `{:provider_response_invalid, field}` that nobody had mapped, and this
      # test would go on claiming total coverage — the same hole as the literal
      # copy and the filtering comprehension this file has now shed twice.
      {:type, _, :tuple, [{:atom, _, :provider_request_failed} | _rest]} ->
        []

      other ->
        flunk("""
        Ezagent.DomainGit.Error.t() gained a member shape this gate cannot read,
        so it can no longer prove every member is mapped:

            #{inspect(other)}

        Teach this function that shape, or the totality claim is false.
        """)
    end)
  end
end
