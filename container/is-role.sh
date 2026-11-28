#!/bin/sh
# is-role.sh <role>|primary: exit 0 only inside that role's own claude. start.sh sets CLAUDE_ROLE_PID to
# its own pid (CLAUDE_ROLE names the role, manager when unset), and background sessions inherit
# both, so also require that the nearest claude ancestor of the caller was started by start.sh
# itself. `primary` stands for the primary role (HOMUN_PRIMARY, manager when unset): the hooks of
# the session the cockpit opens on ask for it, never for a role key. Shared by the role-only hooks.
primary=${HOMUN_PRIMARY:-manager}
want=$1
[ "$want" != primary ] || want=$primary
[ "${CLAUDE_ROLE:-$primary}" = "$want" ] || exit 1
[ -n "${CLAUDE_ROLE_PID:-}" ] || exit 1
pid=$PPID
while [ "$pid" -gt 1 ] && [ "$(head -zn1 "/proc/$pid/cmdline" 2>/dev/null | tr -d '\0' | sed 's#.*/##')" != claude ]; do
	pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || exit 1
done
parent=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || exit 1
# start.sh may run a role's claude under compact-relay (python3) or `homund session relay`: step over that one hop
case "$(tr '\0' ' ' <"/proc/$parent/cmdline" 2>/dev/null)" in
*/compact-relay\ * | *homund\ session\ relay\ *) parent=$(awk '{print $4}' "/proc/$parent/stat" 2>/dev/null) || exit 1 ;;
esac
[ "$parent" = "$CLAUDE_ROLE_PID" ]
