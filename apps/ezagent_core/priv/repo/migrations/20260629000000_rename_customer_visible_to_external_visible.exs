defmodule EzagentCore.Repo.Migrations.RenameCustomerVisibleToExternalVisible do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE messages
       SET visibility = 'external_visible'
     WHERE visibility = 'customer_visible'
    """)
  end

  def down do
    execute("""
    UPDATE messages
       SET visibility = 'customer_visible'
     WHERE visibility = 'external_visible'
    """)
  end
end
