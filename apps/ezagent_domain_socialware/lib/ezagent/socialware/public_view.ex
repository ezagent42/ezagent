defmodule Ezagent.Socialware.PublicView do
  @moduledoc """
  Whether a socialware session is **anonymously viewable** (issue #51).

  `public_view` is a **SessionTemplate-level config** (spec §3.5, OQ-6): a session
  is anonymous-viewable iff the SessionTemplate it was materialized from declares
  `public_view: true` in its content. The decision is made ONCE at the authorized
  creation chokepoint (the Template), not re-litigated per session by a URL holder.

  ## STATUS — surface defined, resolver PENDING

  The Template-resolution + `:public_view` content-key plumbing is NOT yet built
  (the `anon_public_view_test.exs` cases are `@tag :pending_impl` / `:skip`). This
  module currently fails CLOSED: an un-resolvable / un-flagged session is NOT
  publicly viewable. The pending implementation must:

    1. add `:public_view` to `Ezagent.Entity.SessionTemplate`'s `@config_atom_keys`
       so a string-keyed (JSON-boundary) flag atom-coerces into persisted content;
    2. resolve the session's materializing Template (its working-copy / source
       template URI) and read the `public_view` content flag;
    3. default private (fail-closed) when no Template or flag is present.

  Until then, `public_view?/1` returns `false` for every session — the SAFE default
  (anonymous access is fully closed, never accidentally open). This is NOT a shim
  that masks a bug: it is the fail-closed terminal state of an unfinished feature,
  and the `:skip`-tagged tests are the executable definition of the finished one.
  """

  @doc """
  Whether `session_uri`'s materializing Template declares `public_view: true`.

  Fail-closed: returns `false` for any session whose Template cannot be resolved or
  does not declare the flag. (PENDING: see the moduledoc — currently always
  `false`.)
  """
  @spec public_view?(URI.t()) :: boolean()
  def public_view?(%URI{scheme: "session"}), do: false
  def public_view?(_), do: false
end
