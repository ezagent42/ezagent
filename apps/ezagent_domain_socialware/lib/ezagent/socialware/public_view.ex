defmodule Ezagent.Socialware.PublicView do
  @moduledoc """
  Whether a socialware session is **anonymously viewable** (issue #51).

  `public_view` is a **SessionTemplate-level config** (spec §3.5, OQ-6): a session
  is anonymous-viewable iff the SessionTemplate it was materialized from declares
  `public_view: true` in its content. The decision is made ONCE at the authorized
  creation chokepoint (the Template), not re-litigated per session by a URL holder.

  ## Resolution

  `public_view?/1`:

    1. reads the session's `:session` slice (`Ezagent.Kind.get_slice/2`);
    2. takes the materializing Template URI off the durable
       `template_working_copy.session_template_uri`;
    3. reads that Template's content (`Ezagent.Entity.Session.read_template_content/1`)
       and returns `true` ONLY for an explicit `public_view: true`.

  Fail-closed everywhere: a non-session URI, an unreadable slice, a session with no
  materializing Template, a working-copy pointer that is not a **same-workspace
  session-template**, an unreadable Template, or a flag that is anything other than
  the explicit boolean `true` all yield `false` — anonymous access defaults fully
  closed, never accidentally open. The
  `:public_view` content key is declared in `Ezagent.Entity.SessionTemplate`'s
  `@config_atom_keys` so a JSON-boundary (string-keyed) flag atom-coerces into
  persisted content.
  """

  @doc """
  Whether `session_uri`'s materializing Template declares `public_view: true`.

  Fail-closed: returns `false` for any session whose Template cannot be resolved or
  does not declare the flag. (PENDING: see the moduledoc — currently always
  `false`.)
  """
  @spec public_view?(URI.t()) :: boolean()
  def public_view?(%URI{scheme: "session"} = session_uri) do
    with {:ok, slice} <- read_session_slice(session_uri),
         %URI{} = template_uri <- materializing_template_uri(slice),
         :ok <- validate_template_uri(template_uri, session_uri),
         {:ok, content} <- Ezagent.Entity.Session.read_template_content(template_uri) do
      flag(content)
    else
      _ -> false
    end
  end

  def public_view?(_), do: false

  # Defence-in-depth: the working-copy pointer is system-rewritable, so before
  # trusting it as the public-view provenance, require it to be a SESSION-TEMPLATE
  # URI in the SAME workspace as the session. A stale/repaired/repointed pointer to
  # a non-session-template or a foreign-tenant template fails closed — a private
  # session can never be made public by pointing at another workspace's public
  # template. (The URL-holder threat is already closed: `set_working_copy` is not a
  # user-facing dispatch — see `ConfigActions`.)
  defp validate_template_uri(%URI{scheme: "template"} = template_uri, %URI{} = session_uri) do
    with true <- Ezagent.URI.type?(template_uri, :session),
         ws when ws != :any <- Ezagent.URI.workspace_of(session_uri),
         tws when tws != :any <- Ezagent.URI.workspace_of(template_uri),
         true <- URI.to_string(tws) == URI.to_string(ws) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_template_uri(_, _), do: :error

  defp read_session_slice(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, slice} when is_map(slice) -> {:ok, slice}
      _ -> :error
    end
  end

  # The session's materializing Template URI lives on its durable
  # `template_working_copy` (`%{… session_template_uri: uri}`), set at session
  # creation. Missing / not-yet-materialized → nil → fail-closed.
  defp materializing_template_uri(slice) do
    slice
    |> Map.get(:template_working_copy, %{})
    |> case do
      wc when is_map(wc) ->
        Map.get(wc, :session_template_uri) || Map.get(wc, "session_template_uri")

      _ ->
        nil
    end
  end

  # `true` ONLY for an explicit boolean `true`. A string `"true"`, `false`, nil, or
  # any other value is private (fail-closed) — schema/JSON drift must never open a
  # template. Atom key takes precedence over the string key via `Map.fetch/2` (NOT
  # `||`, which would treat a legitimate `public_view: false` as absent and fall
  # through to a string-keyed `"public_view" => "true"`).
  defp flag(content) when is_map(content) do
    case fetch_flag(content) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp flag(_), do: false

  defp fetch_flag(content) do
    case Map.fetch(content, :public_view) do
      {:ok, _} = hit -> hit
      :error -> Map.fetch(content, "public_view")
    end
  end
end
