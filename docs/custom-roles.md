# Host-local roles

The repository ships neutral role words only (`roles/roles.toml`, `manager/ROLES.md`). Names,
personalities and roles one host needs but others do not live outside it, one JSON file per role in

    ${XDG_CONFIG_HOME:-~/.config}/homun/roles/<key>.json

The launcher mounts that directory read-only into every container at `/run/homun-roles`.

A file whose `<key>` is a built-in role overrides the fields it sets; any other key is a new role.
The fields are those of `container/roles.json` (`name`, `status`, `emoji`, `colour`, `job`,
`trigger`, `model`, `may`, `never`, `reports`), plus:

- `identity`: text put first in the role's session prompt (container/start.sh).
- `container`: `true` runs the role in a container of its own, `homun-<key>`, through the same path
  as the mechanic's: it starts with every `homun container restart`, the host supervisor keeps it up,
  and `CLAUDE_ROLE=<key>` makes `container/is-role.sh <key>` true inside it. Its guide, start-up and
  settings may still come from `container/<key>/` (`CLAUDE.md`, `start.sh`) like a built-in role's.
- `seat`, `session`, `access`, `health`, `restart`: what that container is built from, the same
  fields the shipped manifests use (described at the top of `lib/roles.nu`). All optional: without
  them the container gets `~/claude`, its own Claude state and nothing of the other roles'. For
  example `"access": {"notify": true}` gives it desktop notifications. Check the result with
  `homun container plan <key>`.
- `session` and `wake` also say how the session is launched (`container/start.sh` reads them
  through `container/role-manifest.sh`): `session.model`, `session.first_prompt`,
  `session.workdir`, `session.name` (the plate, default the key), `session.mode`, and
  `wake.channel` / `wake.watch` for a role that brings its own channel plugin and watcher under
  `container/`. Without them the role's first prompt tells it to wait for the user, and it works
  in the launcher checkout.
- `"seat": {"kind": "pane", "in": "manager"}` instead of a container: the role's session runs
  inside that role's container, started with `homun role attach <key>`.

A new role, for example:

```json
{
  "name": "Reviewer",
  "emoji": "🔹",
  "colour": [128, 128, 128],
  "job": "Reviews open branches before they merge.",
  "model": "Sonnet, low effort.",
  "identity": "You are the reviewer role.",
  "container": true
}
```

Commands, on the host:

```nu
homun role show            # every role; `local` says override or new
homun role add reviewer    # write a file to edit (a built-in key gets an override stub)
homun role del reviewer    # remove the file, stopping its container
homun role start reviewer  # also stop, restart, attach (any role with a container)
```

`bin/claude-roles list|show` merge the same files; `bin/claude-roles doc` stays on the shipped
manifests, so `manager/ROLES.md` never carries a local name.
