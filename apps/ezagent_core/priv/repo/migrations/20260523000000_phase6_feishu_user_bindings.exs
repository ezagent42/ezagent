defmodule EzagentCore.Repo.Migrations.Phase6FeishuUserBindings do
  use Ecto.Migration

  def change do
    # Phase 6 PR 15: feishu open_id ↔ local user URI binding.
    #
    # `open_id` is the Feishu-side identity (e.g. "ou_6b11faf8e9..."),
    # `user_uri` is the bound Ezagent User Kind URI (e.g. "entity://user/default/linyilun").
    #
    # Same open_id can bind to exactly one user (PK on open_id).
    # Reverse direction is many-to-one (one user may have multiple
    # open_ids — different brands/apps), so no unique constraint on
    # user_uri.
    create table(:feishu_user_bindings, primary_key: false) do
      add :open_id, :string, primary_key: true
      add :user_uri, :string, null: false
      add :bound_by, :string, null: false
      add :bound_at, :utc_datetime_usec, null: false
    end

    create index(:feishu_user_bindings, [:user_uri], name: :feishu_user_bindings_user_uri_index)
  end
end
