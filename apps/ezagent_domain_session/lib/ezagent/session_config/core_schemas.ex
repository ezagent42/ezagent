defmodule Ezagent.Session.Config.CoreSchemas do
  @moduledoc false

  @spec schemas() :: [map()]
  @doc false
  def schemas do
    [
      %{
        "name" => "add_managed_member",
        "description" =>
          "Spawn a worker agent from an AgentTemplate and join it to your " <>
            "session as a MEMBER with a stable role_name. The member is " <>
            "reached by rules targeting its role_name (see " <>
            "define_rule_set_rule). Replaces the retired add_agent_slot " <>
            "(a slot was just a member with extra facets).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "source_agent_template_uri" => %{
              "type" => "string",
              "description" => "AgentTemplate URI to spawn the member from."
            },
            "role_name" => %{
              "type" => "string",
              "description" =>
                "Stable per-session alias for this member (rules/legends target it)."
            },
            "in_session_template" => %{
              "type" => "boolean",
              "description" =>
                "Whether this member is captured in a SessionTemplate snapshot " <>
                  "(true for a persistent team member). Defaults to true."
            }
          },
          "required" => ["source_agent_template_uri", "role_name"]
        }
      },
      %{
        "name" => "add_participant",
        "description" =>
          "Adopt an existing agent into your session as a MEMBER with a " <>
            "stable role_name. Use this only when the worker already exists; " <>
            "new managed workers should use add_managed_member.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "ref" => %{
              "type" => "string",
              "description" => "Existing agent URI to join to this session."
            },
            "role_name" => %{
              "type" => "string",
              "description" =>
                "Stable per-session alias for this member (rules/legends target it)."
            },
            "in_session_template" => %{
              "type" => "boolean",
              "description" =>
                "Whether this member is captured in a SessionTemplate snapshot. Defaults to true."
            }
          },
          "required" => ["ref", "role_name"]
        }
      },
      %{
        "name" => "update_member_template",
        "description" =>
          "Swap a managed member's source AgentTemplate and REGENERATE the " <>
            "member: terminate the old worker, spawn a fresh one from the new " <>
            "template at the SAME role_name, and re-join it. Use this to change " <>
            "a member's blueprint (flavor / cwd / skills / caps) after adding " <>
            "it. Routing rules keyed on the role_name re-resolve automatically.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "role_name" => %{
              "type" => "string",
              "description" => "The member role_name to regenerate."
            },
            "new_source_template_uri" => %{
              "type" => "string",
              "description" =>
                "The new AgentTemplate URI to " <>
                  "rebuild the member from."
            }
          },
          "required" => ["role_name", "new_source_template_uri"]
        }
      },
      %{
        "name" => "remove_member",
        "description" =>
          "Remove a session member by role_name: terminate the worker you " <>
            "spawned and prune routing rules naming it. Idempotent. Reports " <>
            "the rule-set impact (deleted vs repointed rules). Replaces the " <>
            "retired remove_agent_slot.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "role_name" => %{
              "type" => "string",
              "description" => "The member role_name to remove."
            }
          },
          "required" => ["role_name"]
        }
      },
      %{
        "name" => "define_rule_set_rule",
        "description" =>
          "Add a SINGLE-RECEIVER routing rule to a named rule-set: when a " <>
            "message matches the matcher, deliver it to the member named by " <>
            "receiver_role_name, optionally rendered with a prompt template. " <>
            "Rule-sets express multi-agent flows as static {from: X} -> Y " <>
            "rules (NO model-computed baton). Replaces write_matcher.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "matcher_ast" => %{
              "type" => "object",
              "description" =>
                "A routing matcher in JSON form, e.g. " <>
                  ~s({"type":"mention","arg":"传话游戏"} or {"type":"from","arg":"<member-uri>"}.)
            },
            "receiver_role_name" => %{
              "type" => "string",
              "description" =>
                "The member role_name (or concrete URI) the matched message routes to."
            },
            "rule_set" => %{
              "type" => "string",
              "description" => "Name of the rule-set this rule belongs to (the team-flow group)."
            },
            "position" => %{
              "type" => "integer",
              "description" => "Ordinal position of this rule within the rule-set (default 0)."
            },
            "prompt_template_ref" => %{
              "type" => "string",
              "description" =>
                "Optional — name of a prompt template (see define_prompt_template) " <>
                  "rendered into the delivered message."
            }
          },
          "required" => ["matcher_ast", "receiver_role_name", "rule_set"]
        }
      },
      %{
        "name" => "define_prompt_template",
        "description" =>
          "Install a named prompt template on your session. Rules reference " <>
            "it via prompt_template_ref; it is rendered at delivery with " <>
            "variables like {body}/{sender}. Merges into the existing map.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "The prompt template name."},
            "template" => %{
              "type" => "string",
              "description" =>
                "The template string, e.g. " <> ~s("接龙：{body}（by {sender}）". {body} is required.)
            }
          },
          "required" => ["name", "template"]
        }
      },
      %{
        "name" => "define_legend",
        "description" =>
          "Front a rule-set with a @legend handle: a user-facing name that " <>
            "collapses a team (members by role_name) and triggers its " <>
            "rule-set flow. @legend resolves through the legend registry to " <>
            "the rule-set's entry rule.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "legend_name" => %{"type" => "string", "description" => "The @-handle, e.g. 传话游戏."},
            "member_role_names" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Role_names of the team members this legend collapses."
            },
            "bound_rule_set" => %{
              "type" => "string",
              "description" => "The rule-set name @legend triggers."
            },
            "fold" => %{
              "type" => "boolean",
              "description" =>
                "Whether the legend collapses (folds) the member set. Defaults to true."
            }
          },
          "required" => ["legend_name", "member_role_names", "bound_rule_set"]
        }
      },
      %{
        "name" => "update_template",
        "description" =>
          "Snapshot the current session as a NEW VERSION of the parent " <>
            "SessionTemplate it was instantiated from. Persists a real, " <>
            "content-addressed template version.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      },
      %{
        "name" => "save_template_as",
        "description" =>
          "Snapshot the current session as the FIRST VERSION of a NEW " <>
            "SessionTemplate family under the given name.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "new_name" => %{
              "type" => "string",
              "description" => "Name for the new template family."
            }
          },
          "required" => ["new_name"]
        }
      },
      %{
        "name" => "migrate_session",
        "description" =>
          "Migrate this live session to an immutable SessionTemplate version. " <>
            "Changed members are regenerated through update_member_template, " <>
            "session-scoped routing rules are replaced, and a resumable ledger " <>
            "is kept until the pin advances.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "target_session_template_uri" => %{
              "type" => "string",
              "description" => "Immutable session-template target URI (the versioned @hash form)."
            }
          },
          "required" => ["target_session_template_uri"]
        }
      },
      %{
        "name" => "list_templates",
        "description" =>
          "List the AgentTemplates and SessionTemplates visible to you in " <>
            "your workspace. Results are filtered by your capabilities.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name_filter" => %{
              "type" => "string",
              "description" => "Optional substring filter on template names."
            }
          },
          "required" => []
        }
      },
    ]
  end
end
