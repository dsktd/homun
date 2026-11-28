# CLAUDE.md

Start with AGENTS.md, the canonical document for every agent (what Homun is, setup, operation, state, troubleshooting, the rules inside the containers):

@AGENTS.md

Specific to Claude Code:

- Sessions inside a Homun container load the `homun` skill from the plugin in `container/channels/homun/` (`skills/homun/SKILL.md`). Change it with every user-facing change and bump `version` in that plugin's `.claude-plugin/plugin.json`, or running sessions keep the old copy.
- Hooks, permissions and the channel allowlist of the containers' Claude Code are in `managed-settings.json`; the hook scripts are in `container/`.
- The development reference (every command and component in detail) is in `docs/development.md`.
