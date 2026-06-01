defmodule Ezagent.Routing.PromptTemplate do
  @moduledoc """
  Named prompt-template render engine (team-routing-unification §3.4).

  A prompt template is a flat string with `{var}` placeholders. At delivery,
  the matched rule's `prompt_template_ref` (see `Ezagent.Routing.Resolver`
  ctx) names a template; this module renders it over a `vars` map built from
  the delivered message + recipient, and the result is what the recipient
  receives (agent payload) or sees (human render-suffix — a later PR).

  v1 is DELIBERATELY simple: flat single-pass substitution over a FIXED,
  documented variable set — NO conditionals/loops/partials (that richer
  language is explicitly out of scope, spec §7). `{body}` MUST appear in a
  template (validated at write time) so the original message is never
  silently dropped.

  Path-A (spec §3.4): rendering is a single function applied at the existing
  per-recipient delivery seam — NOT a registered hook subsystem (deferred).
  """

  @typedoc "The fixed v1 template variable set."
  @type vars :: %{optional(:sender | :flavor | :body | :session | :sent_at) => term()}

  @doc """
  The fixed set of variable names a v1 template may reference (without the
  surrounding braces). Surfaced for validation + operator UI.
  """
  @spec allowed_vars() :: [atom()]
  def allowed_vars, do: [:sender, :flavor, :body, :session, :sent_at]

  @doc """
  Validate a template string. The only hard rule (v1): it MUST contain the
  `{body}` placeholder, so rendering can never silently drop the original
  message. Returns `:ok` or `{:error, :body_placeholder_required}`.
  """
  @spec validate(String.t()) :: :ok | {:error, :body_placeholder_required | :not_a_string}
  def validate(template) when is_binary(template) do
    if String.contains?(template, "{body}") do
      :ok
    else
      {:error, :body_placeholder_required}
    end
  end

  def validate(_), do: {:error, :not_a_string}

  @doc """
  Render `template` by substituting each `{key}` with the matching value from
  `vars` (single pass, flat). Keys absent from `vars` are left as-is (a
  literal `{unknown}` survives — never raises). Values are stringified.

  ## Examples

      iex> Ezagent.Routing.PromptTemplate.render("hi {sender}: {body}", %{sender: "alice", body: "yo"})
      "hi alice: yo"

      iex> Ezagent.Routing.PromptTemplate.render("{body}", %{})
      "{body}"
  """
  @spec render(String.t(), vars()) :: String.t()
  def render(template, vars) when is_binary(template) and is_map(vars) do
    Enum.reduce(vars, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", stringify(value))
    end)
  end

  defp stringify(v) when is_binary(v), do: v
  defp stringify(%URI{} = u), do: URI.to_string(u)
  defp stringify(nil), do: ""
  defp stringify(v), do: to_string(v)
end
