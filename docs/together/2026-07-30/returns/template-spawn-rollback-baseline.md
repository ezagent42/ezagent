# Together Return: Template Spawn Rollback Baseline

> **Task:** restore the three template-spawn rollback failures present on main
> **Branch:** `fix/template-spawn-rollback-baseline`
> **Dev:** Codex
> **returned_at:** 2026-07-30 16:08 +0800
> **deadline:** not provided
> **deadline_status:** out_of_scope

## Scope and result

- Normalize the post-display-profile test hook so its tagged error is not
  wrapped a second time.
- Preserve compound fail-loud errors whenever rollback cleanup is incomplete.
- Make the fallback sandbox test template implement the complete extension
  callback trio and safely destroy only its canonical config directory.
- Add direct coverage proving a mismatched directory and sentinel survive.

## TDD evidence

- RED: two post-profile cases returned
  `{:error, {:error, :injected_post_profile_failure}}`.
- RED: behavior-overlay rollback reported
  `config_dir_destroy_unsupported`.
- Review RED: an intentionally unguarded fixture callback deleted the
  mismatched sentinel directory.
- GREEN after latest-main rebase:
  - sandbox-materialization file: 23 tests, 0 failures;
  - template extension contract invariant: 1 test, 0 failures;
  - test-environment forced warnings-as-errors compilation: exit 0;
  - `mix format --check-formatted`: exit 0;
  - `git diff --check`: exit 0.

All local database commands used `POSTGRES_PORT=15432` and an isolated
`MIX_TEST_PARTITION`.

## Review

Independent review initially found two Minor fixture-hardening items and no
Critical or Important findings. Both Minors were fixed. Re-review reported no
remaining findings and `Ready to merge: Yes`.

## Full gate

The authoritative post-rebase `mix precommit` is started separately and its
terminal result will be recorded on the PR before merge.

## Merge request

Merge this isolated baseline repair before replaying PR #1501. Do not fold the
template-spawn changes into the capability-convergence branch.
