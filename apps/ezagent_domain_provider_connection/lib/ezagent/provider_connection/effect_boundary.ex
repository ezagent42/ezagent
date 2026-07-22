defmodule Ezagent.ProviderConnection.EffectBoundary do
  @moduledoc false

  # Driver and credential-backend effect calls cross the trust boundary into
  # plugin code. A plugin that raises, throws, or exits can carry a provider
  # response body or credential material in the payload; letting it propagate
  # would write that payload into Kind runtime crash logs and the
  # caller-visible `{:error, {:behavior_exception, _, _}}` tuple — the secret
  # boundary red line (design §14 / handoff §5). Every effect call passes
  # through here so the payload is normalized to a closed error code at the
  # boundary; the closed code is chosen by the call site from the same
  # vocabulary its returned-error path already uses.

  @doc false
  @spec invoke((-> term()), atom()) :: term()
  def invoke(effect, closed_error) when is_function(effect, 0) and is_atom(closed_error) do
    try do
      effect.()
    rescue
      _error -> {:error, closed_error}
    catch
      _kind, _reason -> {:error, closed_error}
    end
  end
end
