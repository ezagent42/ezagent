defmodule Ezagent.Identity.CapReconciler do
  @moduledoc """
  Pure planner for capability signing self-heal.

  Signedness is classified exclusively by `Ezagent.Cap.signed_and_valid?/2`.
  Policy modules own the authorization recipe for their cap classes; an
  unclaimed or failed policy result is quarantined and never blind-signed.
  """

  alias Ezagent.Capability

  @type reissue_entry :: %{
          cap: Capability.t(),
          class: atom(),
          action: Ezagent.Cap.ReissuePolicy.action()
        }
  @type quarantine_entry :: %{cap: term(), class: atom(), reason: term()}
  @type plan :: %{
          keep: [Capability.t()],
          reissue: [reissue_entry()],
          quarantine: [quarantine_entry()]
        }

  @doc false
  @spec plan(Enumerable.t(), URI.t(), [module()]) :: plan()
  def plan(held_caps, %URI{} = receiver_uri, policies) when is_list(policies) do
    held_caps
    |> Enum.reduce(empty_plan(), &classify_cap(&1, &2, receiver_uri, policies))
    |> reverse_buckets()
  end

  @doc false
  @spec plan(Enumerable.t(), URI.t()) :: plan()
  def plan(held_caps, %URI{} = receiver_uri) do
    plan(held_caps, receiver_uri, Ezagent.Cap.ReissuePolicy.Registry.policies())
  end

  defp empty_plan, do: %{keep: [], reissue: [], quarantine: []}

  defp classify_cap(%Capability{} = cap, plan, receiver_uri, policies) do
    if Ezagent.Cap.signed_and_valid?(cap, receiver_uri) do
      update_in(plan.keep, &[cap | &1])
    else
      classify_legacy(cap, plan, receiver_uri, policies)
    end
  end

  defp classify_cap(cap, plan, _receiver_uri, _policies) do
    entry = %{cap: cap, class: :unknown, reason: :invalid_cap_shape}
    update_in(plan.quarantine, &[entry | &1])
  end

  defp classify_legacy(cap, plan, receiver_uri, policies) do
    case claim(cap, policies) do
      {:ok, policy, class} -> apply_policy(policy, class, cap, receiver_uri, plan)
      :not_found -> quarantine(plan, cap, :unknown, :no_resolver)
      {:error, reason} -> quarantine(plan, cap, :unknown, {:classifier_error, reason})
    end
  end

  defp claim(cap, policies) do
    Enum.reduce_while(policies, :not_found, fn policy, _acc ->
      case safe_apply(policy, :classify, [cap]) do
        {:ok, {:ok, class}} when is_atom(class) -> {:halt, {:ok, policy, class}}
        {:ok, :not_mine} -> {:cont, :not_found}
        {:ok, other} -> {:halt, {:error, {:invalid_classification, policy, other}}}
        {:error, reason} -> {:halt, {:error, {policy, reason}}}
      end
    end)
  end

  defp apply_policy(policy, class, cap, receiver_uri, plan) do
    case safe_apply(policy, :reissue_action, [cap, receiver_uri]) do
      {:ok, {:reissue, _authorization} = action} -> reissue(plan, cap, class, action)
      {:ok, {:refresh_binding, _ref} = action} -> reissue(plan, cap, class, action)
      {:ok, {:quarantine, reason}} -> quarantine(plan, cap, class, reason)
      {:ok, {:error, reason}} -> quarantine(plan, cap, class, {:policy_error, reason})
      {:ok, other} -> quarantine(plan, cap, class, {:invalid_policy_action, other})
      {:error, reason} -> quarantine(plan, cap, class, {:policy_exception, reason})
    end
  end

  defp reissue(plan, cap, class, action) do
    entry = %{cap: cap, class: class, action: action}
    update_in(plan.reissue, &[entry | &1])
  end

  defp quarantine(plan, cap, class, reason) do
    entry = %{cap: cap, class: class, reason: reason}
    update_in(plan.quarantine, &[entry | &1])
  end

  defp safe_apply(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reverse_buckets(plan) do
    %{
      keep: Enum.reverse(plan.keep),
      reissue: Enum.reverse(plan.reissue),
      quarantine: Enum.reverse(plan.quarantine)
    }
  end
end
