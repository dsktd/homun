#!/bin/sh
# role-manifest.sh: sourced with $role set (and $here, the directory of the registry, else
# /opt/homun). Reads how the role's session is launched from its manifest: the registry roles.json
# (built from roles/roles.toml; ROLES_FILE names another) with the role's host-local file
# (/run/homun-roles/<role>.json, lib/roles.nu) laid over it, a record merging and anything else
# replacing. One jq call sets, as m_<name>:
#   seat        container | pane
#   name model settings workdir identity mode prompt   of `session` (name defaults to the key)
#   relay rotate recycle boot                          of `session`, true or false (recycle: true)
#   impl        of `session`: `scripts` (the default) or `homund` (homund session runs it)
#   services update                                    of `access`, true or false
#   chan_plugin chan_state chan_when chan_prompt       of `wake.channel`
#   chan_env    its env, one KEY=value a line
#   watch       the script watchers of `wake.watch`, one "needs|log|cmd" a line
#   local_identity   the `identity` text of the host-local file
# @root and @home at the start of a path are filled in. A role without a manifest gets the
# defaults: a container seat, its key as its name, everything else empty or false.
m_reg=${ROLES_FILE:-${here:-/opt/homun}/roles.json}
m_loc=${HOMUN_ROLES_DIR:-/run/homun-roles}/$role.json
m_jq='
def at: sub("^@root"; $home + "/claude") | sub("^@home"; $home);
((.[0][$r] // {}) * (.[1] // {})) as $m
| ($m.session // {}) as $s | ($m.access // {}) as $a | ($m.wake // {}) as $w | ($w.channel // {}) as $c
| {
    seat: ($m.seat.kind? // "container"),
    name: ($s.name // $r), model: ($s.model // ""), settings: ($s.settings // ""),
    workdir: ($s.workdir // "" | at), identity: ($s.identity // ""), mode: ($s.mode // ""),
    prompt: ($s.first_prompt // ""),
    relay: ($s.relay // false), rotate: ($s.rotate // false), recycle: ($s.recycle != false),
    boot: ($s.boot_record // false), impl: (if $s.impl == "homund" then "homund" else "scripts" end),
    services: ($a.services // false), update: ($a.update // false),
    chan_plugin: ($c.plugin // ""), chan_state: ($c.state // "" | at), chan_when: ($c.when // "" | at),
    chan_prompt: ($c.first_prompt // ""),
    chan_env: ([$c.env // {} | to_entries[] | "\(.key)=\(.value | tostring | at)"] | join("\n")),
    watch: ([$w.watch // [] | .[] | select(.kind == "script") | [.needs // "", (.log // "" | at), .cmd] | join("|")] | join("\n")),
    local_identity: (.[1].identity? // "")
  }
| to_entries[] | "m_\(.key)=\(.value | tostring | @sh)"'
if [ -r "$m_loc" ] && m_out=$(jq -rs --arg r "$role" --arg home "$HOME" "$m_jq" "$m_reg" "$m_loc" 2>/dev/null); then
	:
elif m_out=$(jq -rs --arg r "$role" --arg home "$HOME" "$m_jq" "$m_reg" 2>/dev/null); then
	[ ! -e "$m_loc" ] || echo "role-manifest: $m_loc cannot be read; the $role starts without it" >&2
else
	echo "role-manifest: $m_reg cannot be read; the $role starts with the defaults" >&2
	m_out=
fi
m_seat=container m_name=$role m_model='' m_settings='' m_workdir='' m_identity='' m_mode='' m_prompt=''
m_relay=false m_rotate=false m_recycle=true m_boot=false m_impl=scripts m_services=false m_update=false
m_chan_plugin='' m_chan_state='' m_chan_when='' m_chan_prompt='' m_chan_env='' m_watch='' m_local_identity=''
eval "$m_out"
unset m_jq m_out
