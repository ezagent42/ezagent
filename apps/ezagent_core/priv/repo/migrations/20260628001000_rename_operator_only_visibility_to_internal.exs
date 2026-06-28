defmodule EzagentCore.Repo.Migrations.RenameOperatorOnlyVisibilityToInternal do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE messages
       SET visibility = 'internal'
     WHERE visibility = 'operator_only'
    """)
  end

  def down do
    execute("""
    UPDATE messages
       SET visibility = 'operator_only'
     WHERE visibility = 'internal'
    """)
  end
end
