defmodule Ezagent.Identity.TargetAuthority do
  @moduledoc """
  Installs the explicit admin-to-owner delegation for one concrete Kind.

  Every Kind authority is born with only its sealed, target-signed canonical
  admin anchor. Reviewed creation/materialization paths call `ensure/2` before
  the business owner issues capabilities on that target. The resulting
  `Cap.Grant :grant` artifact is signed by the target Kind and stored on the
  owner; subsequent issuance therefore records the owner as `granted_by`
  instead of using ambient admin authority.

  This is part of the reviewed-code (Path A) model. It is not a boundary
  against malicious code already executing in the BEAM.
  """

  alias Ezagent.{Cap, Capability}

  @store_timeout_ms 2_000

  @doc "Ensure `owner` holds target-signed grant authority over `target`."
  @spec ensure(URI.t(), URI.t()) :: :ok | {:error, term()}
  def ensure(%URI{} = owner, %URI{} = target) do
    target = Ezagent.URI.instance(target)
    admin = Ezagent.Entity.User.admin_uri()

    if same_uri?(owner, admin) do
      :ok
    else
      with {:ok, kind_type} <- target_kind_type(target),
           requested <-
             Capability.cap(
               kind_type,
               Ezagent.Cap.Grant,
               :grant,
               target,
               Capability.workspace_of(target)
             ),
           {:ok, authority_cap} <- Cap.issue({:admin, admin}, owner, requested),
           :ok <- Ezagent.Identity.absorb_cap(owner, authority_cap),
           :ok <-
             Ezagent.Identity.CapAbsorbAwait.await_exact(
               owner,
               [authority_cap],
               @store_timeout_ms
             ) do
        :ok
      end
    end
  end

  defp target_kind_type(target) do
    if Cap.Authority.current_target?(target) do
      Cap.Authority.current_kind_type()
    else
      # V5 A1c — the `:ezagent_kind_module` framework verb is delivered BY URI
      # through the resolver seam (was `KindRegistry.lookup/1` + a raw
      # `GenServer.call/2`); the pid never enters domain code. The not-
      # registered shape stays `:error` for `ensure/2`'s `with` chain.
      case Ezagent.Runtime.Resolver.call(target, :ezagent_kind_module) do
        {:ok, {:ok, kind_module}} -> {:ok, kind_module.type_name()}
        {:ok, other} -> other
        {:error, :no_such_actor} -> :error
        {:error, _reason} = error -> error
      end
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
  end
end
