# The agent identity (name, pronouns, emoji): one agent.json, read here and by
# container/agent-get (sh) and container/emacs/claude-identity.el.
# Order: $CLAUDE_AGENT_FILE, /run/claude-agent.json (mounted ro), ~/.config/claude/agent.json, ~/claude/.services/identities/agent.json (local only), the repo default.

const DEFAULT = path self ../container/agent.json

def agent-file []: nothing -> path {
    [
        ($env.CLAUDE_AGENT_FILE? | default "")
        /run/claude-agent.json
        ($env.HOME | path join .config claude agent.json)
        ($env.HOME | path join claude .services identities agent.json)
        $DEFAULT
    ] | where {|p| $p != "" and ($p | path exists) } | first
}

# The agent identity: `agent name`, `agent emoji`, `agent json`, `agent help`.
export def main [what?: string]: nothing -> any {
    let a = open (agent-file)
    match $what {
        name => $a.name
        emoji => $a.emoji
        json => $a
        _ => { print "usage: agent name|emoji|json|help (file: $CLAUDE_AGENT_FILE, ~/.config/claude/agent.json, container/agent.json)" }
    }
}
