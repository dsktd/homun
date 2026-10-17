# Key hints derived from the keybinds in zellij/config.kdl: the zjstatus
# `mode_*` lines of the status bar, the rendered layout they go into, and the
# Ctrl+Space ? cheat sheet. Everything starts from `keybinds`, so the three
# can't disagree with the config or with each other.

# Short labels for actions; anything else is the action name split into words
const LABELS = {
    NewPane: "new pane", NewTab: "new tab", CloseFocus: "close",
    GoToNextTab: "next tab", GoToPreviousTab: "prev tab", Detach: "detach",
    Quit: "quit", ToggleFocusFullscreen: "zoom", ToggleFloatingPanes: "float",
    ScrollDown: "down", ScrollUp: "up", HalfPageScrollDown: "½pg down",
    HalfPageScrollUp: "½pg up", PageScrollDown: "pg down", PageScrollUp: "pg up",
    ScrollToBottom: "bottom", ScrollToTop: "top", EditScrollback: "edit",
    UndoRenameTab: "undo", UndoRenamePane: "undo",
}
# Labels for the commands and plugins keys run; anything else is the command name
const RUNS = { "session-manager": "sessions", "claude-update": "update Claude", "claude-changelog": "update changes", "claude-wrapper-keys": "this help" }
# Key names as the status bar shows them
const KEYS = {
    "Ctrl Space": "C-spc", Esc: "esc", Enter: "ret", Down: "↓", Up: "↑",
    PageDown: "pgdn", PageUp: "pgup",
}
# Zellij mode names as zjstatus spells its mode_* settings
const ZJSTATUS_MODES = { entersearch: "enter_search", renametab: "rename_tab", renamepane: "rename_pane" }
# Labels for entering a mode; the rest are the mode name
const MODES = { locked: "back", entersearch: "search" }

# Actions these keys are only input helpers for; they add nothing to a hint
const SILENT = [PaneNameInput TabNameInput SearchInput]

# This checkout's Zellij config
const CONFIG = path self | path dirname | path dirname | path join zellij config.kdl

# `[{mode, binds: [{keys: [..], label}]}]` for every mode in the keybinds block
# of a Zellij config (this checkout's by default), with similar binds folded:
# `1`..`9` into `1-9`, `h`/`j`/`k`/`l` doing the same thing in four directions
# into `hjkl`, and keys sharing a label into one bind.
export def keybinds [config: path = $CONFIG]: nothing -> table<mode: string, binds: list<any>> {
    parse-keybinds (open --raw $config)
    | each {|m| {mode: $m.mode, binds: (fold $m.binds)} }
}

# The zjstatus `mode_*` lines for the status bar
export def status-lines [keybinds: table]: nothing -> list<string> {
    $keybinds | each {|m|
        # The labels end up inside a KDL string; escape just in case one ever contains `\` or `"`
        let hint = $m.binds | each { $"(status-keys $in.keys):($in.label)" } | str join "  " | kdl-escape
        let zj = $ZJSTATUS_MODES | get -o $m.mode | default $m.mode
        $'mode_($zj) "#[bg=blue,fg=black,bold] (title $m.mode) #[bg=default,fg=default] ($hint) "'
    }
}

# The layout template with the status lines in place of its `// hints` line
export def render-layout [template: path, keybinds: table]: nothing -> string {
    let all = open --raw $template | lines
    let at = $all | enumerate | where item =~ '^\s*// hints$' | get -o 0.index
    if $at == null {
        error make { msg: $"no '// hints' placeholder line in ($template)" }
    }
    let indent = $all | get $at | parse -r '^(\s*)' | get 0.capture0
    ($all | first $at)
    | append (status-lines $keybinds | each { $indent + $in })
    | append ($all | skip ($at + 1))
    | str join "\n" | $in + "\n"
}

# The Ctrl+Space ? cheat sheet: one `key  label` column per mode, with the
# small modes stacked so the whole thing is no taller than the biggest mode.
export def cheat-sheet [keybinds: table]: nothing -> string {
    let blocks = $keybinds | each {|m|
        let rows = $m.binds | each {|b| {keys: (sheet-keys $b.keys), label: $b.label} }
        let width = $rows | get keys | str length -g | math max
        [(title $m.mode)]
        | append ($rows | each { $"($in.keys | fill -a left -w $width)  ($in.label)" })
    }
    let height = $blocks | each { length } | math max
    # Greedy: stack blocks (with a blank line between) while they fit under the tallest
    mut columns = []
    mut column = []
    for block in $blocks {
        let joined = if ($column | is-empty) { $block } else { $column | append "" | append $block }
        if ($joined | length) > $height {
            $columns = $columns | append [$column]
            $column = $block
        } else {
            $column = $joined
        }
    }
    let columns = $columns | append [$column]
    let widths = $columns | each { str length -g | math max }
    0..<$height | each {|row|
        $columns | enumerate | each {|c|
            $c.item | get -o $row | default "" | fill -a left -w ($widths | get $c.index)
        } | str join "   " | str trim -r
    } | str join "\n"
}

# Modes are the 4-space-indented blocks; after dropping the `{ floating true; ... }`
# option blocks of Run/LaunchOrFocusPlugin nothing else nests, so regexes suffice.
def parse-keybinds [text: string] {
    $text
    # Comments start a line or follow whitespace outside quotes, so `https://` in a string survives
    | str replace -ra '(?m)^((?:[^"\n]|"[^"\n]*")*?)(^|\s)//[^\n]*' '$1$2'
    | str replace -ra '(?s)(Run|LaunchOrFocusPlugin)((?: "[^"]*")+) \{.*?\}' '$1$2'
    | parse -r '(?sm)^    (\w+) \{(.*?)^    \}'
    | each {|m|
        {
            mode: $m.capture0
            binds: ($m.capture1 | parse -r '(?s)bind ([^{]*?) ?\{([^}]*)\}' | each {|b|
                {
                    keys: ($b.capture0 | parse -r '"([^"]+)"' | get capture0)
                    label: (describe ($b.capture1 | split row -r '[;\n]' | str trim | where $it != ""))
                }
            })
        }
    }
}

# One label for a bind's action list
def describe [actions: list<string>] {
    mut out = []
    for a in $actions {
        let name = $a | split row " " | first
        # The first argument only: a Run's command, not what it is passed
        let rest = $a | str replace -r '^\S+\s*' ''
        let arg = $rest | parse -r '^"([^"]*)"' | get -o 0.capture0 | default $rest
        if $name in $SILENT { continue }
        let label = match $name {
            "SwitchToMode" => ($MODES | get -o $arg | default (mode-name $arg))
            "Run" | "LaunchOrFocusPlugin" => ($RUNS | get -o $arg | default $arg)
            "Search" => (if $arg == "down" { "next" } else { "prev" })
            "MoveFocus" => $"focus ($arg | str lowercase | str substring 0..0)"
            "MovePane" => $"move ($arg | str lowercase | str substring 0..0)"
            "Resize" => ($arg | str lowercase | str replace "increase " "+" | str replace "decrease " "-")
            "GoToTab" => $"tab ($arg)"
            "SearchToggleOption" => (words $arg)
            _ => ($LABELS | get -o $name | default (words $name))
        }
        $out = $out | append $label
    }
    # Returning to locked afterwards is the norm; only mention it when that's all a key does
    if ($out | length) > 1 and ($out | last) == "back" { $out = $out | drop }
    $out | uniq | str join " "
}

# Fold `1`..`9` into one `1-9` bind, `h`/`j`/`k`/`l` doing the same thing in four
# directions ("focus l", "focus d", ...) into one `hjkl` bind, and keys with the
# same label into one bind
def fold [binds: list] {
    let digits = $binds | where ($it.keys | length) == 1 and $it.keys.0 =~ '^\d$'
    let binds = if ($digits | length) > 2 {
        $binds | where $it not-in $digits
            | prepend { keys: [$"($digits | first | get keys.0)-($digits | last | get keys.0)"], label: "tab" }
    } else { $binds }

    let dir = '^(.+?) ?(l|d|u|r|left|down|up|right)$'
    let binds = $binds | insert base {|b|
        if ($b.keys | length) == 1 and ($b.keys.0 | str length) == 1 { $b.label | parse -r $dir | get -o 0.capture0 }
    }
    let groups = $binds | where base != null | group-by --to-table base | where ($it.items | length) == 4
    $binds
    | where {|b| $b.base == null or $b.base not-in $groups.base }
    | reject base
    | append ($groups | each { { keys: [($in.items | get keys | each { first } | str join "")], label: $in.base } })
    | group-by --to-table label
    | each { { keys: ($in.items | get keys | flatten), label: $in.label } }
}

# A mode name in words: `entersearch` -> `enter search`
def mode-name [mode: string] {
    $ZJSTATUS_MODES | get -o $mode | default $mode | str replace -a "_" " "
}

# A mode name as a title: `entersearch` -> `ENTER SEARCH`
def title [mode: string] {
    mode-name $mode | str uppercase
}

# `CaseSensitivity` -> `case sensitivity`
def words [name: string] {
    $name | str replace -ra '(\p{Lu})' ' $1' | str trim | str lowercase
}

def kdl-escape []: string -> string {
    $in | str replace -a '\' '\\' | str replace -a '"' '\"'
}

def status-keys [keys: list<string>] {
    $keys | each {|k| $KEYS | get -o $k | default ($k | str replace -r '^Ctrl (\w)$' 'C-$1') } | str join "/"
}

def sheet-keys [keys: list<string>] {
    $keys | each { str replace -r '^Ctrl (\S+)$' 'Ctrl+$1' } | str join " / "
}
