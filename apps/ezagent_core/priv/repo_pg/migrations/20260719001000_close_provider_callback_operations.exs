defmodule EzagentCore.Repo.Migrations.CloseProviderCallbackOperations do
  use Ecto.Migration

  def change do
    create constraint(
             :provider_connection_operations,
             :provider_connection_operations_callback_fence_check,
             check: """
             operation_class <> 'store'
             OR status NOT IN ('prepared','backend_committed','cleanup_pending')
             OR (
               expected_connection_version IS NOT NULL
               AND attempt_version IS NOT NULL
               AND attempt_claim_token IS NOT NULL
             )
             """
           )

    create constraint(
             :provider_connection_operations,
             :provider_connection_operations_callback_result_check,
             check: """
             operation_class <> 'store'
             OR status NOT IN ('backend_committed','cleanup_pending')
             OR (
               handoff_ref IS NOT NULL
               AND result_ref IS NOT NULL
               AND expected_credential_version IS NOT NULL
             )
             """
           )
  end
end
