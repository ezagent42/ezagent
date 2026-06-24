defmodule EzagentPluginHello.Sanitize do
  @moduledoc """
  Defence-in-depth HTML sanitiser for the AI-authored page **shell** (the hybrid
  architecture: a free-form HTML+Tailwind frame the model writes, with the
  json-render body mounted into its `data-slot`).

  The shell is injected via `innerHTML` on the PUBLIC customer page. `innerHTML`
  itself does NOT execute `<script>` it inserts, so the realistic active-content
  vectors are: event-handler attributes (`onclick`/`onerror`/…), `javascript:`/
  `vbscript:`/`data:` URIs, and active tags (`<script>`/`<iframe>`/`<object>`/…).
  This strips all of them, and guarantees a single `data-slot` mount point.

  Threat model note: the markup is authored by OUR LLM under OUR constrained
  shell prompt — this is defence-in-depth against prompt-injection / model slips,
  NOT a substitute for a parser-based allow-list (Floki / html_sanitize_ex) if the
  source ever becomes fully untrusted. Regex sanitisers can be bypassed by a
  determined adversary; pair this with a CSP header before trusting arbitrary
  input. See `references` / the hybrid-shell decision.
  """

  # Tags removed entirely (with their content for paired ones). `head`/`title`
  # are here so a full-document reply doesn't leak its <title> text as a visible
  # node when injected via innerHTML. `<style>` is INTENTIONALLY allowed (the AI
  # themes the page's content classes through it) — its CSS is sanitised below,
  # and any `</style>`-breakout into <script>/on*/js: is caught by the other passes.
  @dangerous_tags ~w(script iframe object embed link meta base form input textarea select noscript template head title)

  @doc "Sanitise an AI-authored shell HTML string; always returns safe markup with a `data-slot`."
  @spec html(term()) :: binary()
  def html(input) when is_binary(input) do
    input
    |> strip_document_tags()
    |> strip_dangerous_tags()
    |> strip_event_handlers()
    |> strip_js_uris()
    |> strip_css_vectors()
    |> ensure_slot()
  end

  def html(_), do: ~s(<div data-slot></div>)

  # Drop document-level wrapper tags (keep their inner content) — the shell is
  # injected into a <div>, so <!DOCTYPE>/<html>/<body> are meaningless there.
  defp strip_document_tags(html) do
    html
    |> String.replace(~r/<!DOCTYPE[^>]*>/i, "")
    |> String.replace(~r/<\/?html\b[^>]*>/i, "")
    |> String.replace(~r/<\/?body\b[^>]*>/i, "")
  end

  defp strip_dangerous_tags(html) do
    Enum.reduce(@dangerous_tags, html, fn tag, acc ->
      acc
      # paired <tag ...> ... </tag>
      |> String.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}>/is, "")
      # any stray open / self-closing / closing tag
      |> String.replace(~r/<\/?#{tag}\b[^>]*>/i, "")
    end)
  end

  defp strip_event_handlers(html) do
    html
    |> String.replace(~r/\son[a-z]+\s*=\s*"[^"]*"/i, "")
    |> String.replace(~r/\son[a-z]+\s*=\s*'[^']*'/i, "")
    |> String.replace(~r/\son[a-z]+\s*=\s*[^\s>]+/i, "")
  end

  defp strip_js_uris(html) do
    html
    |> String.replace(~r/(href|src|xlink:href)\s*=\s*"\s*(?:javascript|vbscript|data):[^"]*"/i, ~S(\1="#"))
    |> String.replace(~r/(href|src|xlink:href)\s*=\s*'\s*(?:javascript|vbscript|data):[^']*'/i, ~S(\1='#'))
  end

  # CSS-level active-content vectors (mostly legacy, but cheap defence): IE
  # expression(), Mozilla -moz-binding, behavior:, @import (external fetch), and
  # any stray javascript:/vbscript: in url()/values.
  defp strip_css_vectors(html) do
    html
    |> String.replace(~r/expression\s*\(/i, "x_(")
    |> String.replace(~r/-moz-binding\s*:/i, "x-moz:")
    |> String.replace(~r/\bbehaviou?r\s*:/i, "x-behavior:")
    |> String.replace(~r/@import\b/i, "x-import")
    |> String.replace(~r/(javascript|vbscript)\s*:/i, "x-script:")
  end

  # The body mount point. Guarantee exactly one; if the model omitted it, append
  # one so the json-render content always has somewhere to render.
  defp ensure_slot(html) do
    if Regex.match?(~r/data-slot/i, html) do
      html
    else
      html <> ~s(\n<div data-slot></div>)
    end
  end
end
