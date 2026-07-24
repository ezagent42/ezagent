defmodule EzagentCore.Repo.Migrations.AddAgentProfileDisplayNameUniqueness do
  use Ecto.Migration

  @index_name :entity_profiles_agent_workspace_display_name_index
  @agent_uri_predicate "entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'"

  def up do
    deduplicate_legacy_agent_display_names()

    create unique_index(:entity_profiles, [:workspace_uri, :display_name],
             where: @agent_uri_predicate,
             name: @index_name
           )
  end

  def down do
    # The deterministic data repair in `up/0` is deliberately retained: the
    # original duplicate names are ambiguous and cannot be reconstructed.
    drop_if_exists(index(:entity_profiles, [:workspace_uri, :display_name], name: @index_name))
  end

  defp deduplicate_legacy_agent_display_names do
    execute("""
    DO $$
    DECLARE
      duplicate_profile RECORD;
      suffix integer;
      suffix_text text;
      candidate text;
    BEGIN
      FOR duplicate_profile IN
        SELECT entity_uri,
               workspace_uri,
               display_name,
               row_number() OVER (
                 PARTITION BY workspace_uri, display_name
                 ORDER BY entity_uri
               ) AS duplicate_number
          FROM entity_profiles
         WHERE entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'
         ORDER BY workspace_uri, display_name, entity_uri
      LOOP
        IF duplicate_profile.duplicate_number > 1 THEN
          suffix := 2;

          LOOP
            suffix_text := '-' || suffix;
            candidate := left(duplicate_profile.display_name, 255 - char_length(suffix_text)) || suffix_text;

            EXIT WHEN NOT EXISTS (
              SELECT 1
                FROM entity_profiles AS existing_profile
               WHERE existing_profile.workspace_uri = duplicate_profile.workspace_uri
                 AND existing_profile.display_name = candidate
                 AND existing_profile.entity_uri <> duplicate_profile.entity_uri
                 AND existing_profile.entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'
            );

            suffix := suffix + 1;
          END LOOP;

          UPDATE entity_profiles
             SET display_name = candidate
           WHERE entity_uri = duplicate_profile.entity_uri;
        END IF;
      END LOOP;
    END $$;
    """)
  end
end
