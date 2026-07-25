defmodule Ezagent.Kind.Adapters.AuthorityAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.AuthorityPort` (§3.4) —
  delegates to the `Ezagent.Cap.Authority` spine and fronts `Ezagent.Cap` /
  `Ezagent.Cap.Verifier` / `Ezagent.Cap.RuntimeView` for the artifact/view
  rows. Owns the representation checks (§3.4 opacity rule): the authority
  struct is OPAQUE to the framework (`generation/1` is the single field
  read, done HERE), and a non-`Ezagent.Capability` artifact is rejected —
  `{:error, :invalid_artifact}` on the `validate_artifact/2` path, `false`
  on the boolean `verify_artifact/2` path (byte-for-byte today's
  `valid_artifact?/2` fallthrough clause). STAYS in core when the framework
  moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.AuthorityPort

  @impl true
  def open(uri, kind_type, freshness),
    do: Ezagent.Cap.Authority.open(uri, kind_type, freshness)

  @impl true
  def with_authority(token, fun), do: Ezagent.Cap.Authority.with_current(token, fun)

  @impl true
  def regenesis(uri, kind_type, ctx),
    do: Ezagent.Cap.Authority.regenesis(uri, kind_type, ctx)

  @impl true
  def retire(uri), do: Ezagent.Cap.Authority.retire(uri)

  @impl true
  def validate_artifact(artifact, receiver) do
    if is_struct(artifact, Ezagent.Capability) do
      Ezagent.Cap.validate_for_current_target(artifact, receiver)
    else
      {:error, :invalid_artifact}
    end
  end

  @impl true
  def verify_artifact(artifact, presenter) do
    if is_struct(artifact, Ezagent.Capability) do
      Ezagent.Cap.Verifier.valid_artifact?(artifact, presenter)
    else
      false
    end
  end

  @impl true
  def generation(token), do: token.generation

  @impl true
  def verified_set(caps, receiver_uri), do: Ezagent.Cap.verified_set(caps, receiver_uri)

  # KEPT AS-IS (full `state` passed — the self-issue hatch; a later chunk
  # narrows/deletes it — faithful port, do NOT narrow here).
  @impl true
  def with_runtime_view(kind_module, state, fun),
    do: Ezagent.Cap.RuntimeView.with_current(kind_module, state, fun)
end
