# Phase 2: a Nix-based container image (#86)

Design only (2026-11-01). Phase 1 (#85) is live: git, gh, jq, notify-send,
runit, nu and curl come from `container/tools/flake.nix` into the default
Nix profile at first start (`container/entrypoint.sh`, the tools block).

## Goal and constraints

Goal: every tool in the container comes from Nix and the image has no apt.

- Rootless Podman. Root inside is host uid 1000 (`/proc/self/uid_map`:
  `0 1000 1`, `1 100000 65536`).
- No `CAP_SYS_ADMIN`, so no Nix sandbox (`sandbox = false` in the image's
  nix.conf). Builds run as the `nixbld` users (uids 30001-30008, group
  30000, Containerfile), or a builder writing to `$HOME` creates
  `/homeless-shelter` and Nix refuses every build (Containerfile comment).
- `/nix` is the persistent `claude-nix` volume and `~/.cache/nix` is
  `claude-nix-cache` (run.nu). The volume is mounted over the image's
  `/nix`, which is why `nu` is a static tarball in `/usr/local/bin`, not a
  Nix path.

An image that ships a store is hidden by the volume. Two ways out:

1. Keep the image store empty: nothing of value under `/nix` in the image;
   install at first start, as today.
2. Seed the volume from the image on first boot: Podman copies the image's
   content at the mountpoint into an _empty_ named volume on first use
   (copy-up; documented, not tested here). After that the volume wins and
   the image's paths are stale, so later updates go through `nix profile`.

## Option A: `FROM nixos/nix`

Free: a working nix, 32 nixbld users, `sandbox = false`,
`build-users-group = nixbld`, cacert with `SSL_CERT_FILE`, bash, coreutils,
curl, git, PATH through `/nix/var/nix/profiles/default` (built with
`buildLayeredImageWithNixDb`, NixOS/nix `docker.nix`).

Needs work: its nix.conf lacks `experimental-features = nix-command flakes`
and our `sandbox-paths = /bin/sh=/usr/bin/bash-static`; `nu` as login shell
(`/etc/shells`, root's passwd) with `nu` living under `/nix`, hidden by the
volume unless seeded or placed outside; zoneinfo for the `/etc/localtime`
mount; the Rust and Go tools either stay multi-stage and are copied to
`/usr/local/bin` (outside `/nix`) or move into the tools flake. Still a
Dockerfile and `podman build`: moderate change, modest gain.

## Option B: `dockerTools` image from a flake

`pkgs.dockerTools.streamLayeredImage` as a flake output. `Entrypoint`/`Cmd`
as today; `contents`/`extraCommands` provide `/etc/passwd` with the nixbld
users, nix.conf, `/etc/shells`, `/opt/homun`, managed-settings.
The Rust and Go tools become flake packages, so the multi-stage builds go
away. Declarative, pinned by `flake.lock`.

Costs: `nix run .#image | podman load` replaces `podman build . -t claude`
(`just build`/`just update`, `claude-update`, C-SPC u); the build must run
where Nix can build an image (host, or this container under the
no-sandbox nixbld setup: unverified); layers are per store path, so updates
are small but the image is larger than Debian-slim; the `/nix` volume still
hides the image store, so approach 1 or 2 above still applies; Claude Code's
installer (`curl | bash` at first start) needs bash and curl outside `/nix`
or in seeded content.

## Recommendation

Option B, staged so `claude-update` works at every step:

1. Add the flake image output beside the Containerfile; build and
   `podman load` it by hand as `claude-nix-test`. Update path untouched.
2. Empty-store design: bash and curl at a non-volume path, nix and the
   nixbld users, nix.conf, nu, the shims, the Rust and Go tools as flake
   packages. Test with the mechanic container (second role) first.
3. `just build` tries the Nix image and falls back to `podman build`; the
   old Containerfile stays buildable as `Containerfile.debian`.
4. After one clean week, the Nix image is the default; after another,
   remove apt.

Rollback: `homun container build` with the Debian file, or `podman tag` the
previous image. The volume only holds store paths and profiles, so it stays
compatible.

## Step 1: delivered (2026-11-05)

`nix build .#image` (or `just build-nix`, which pipes `nix run .#image` into
`podman load` as `claude-nix:latest`) builds a one-layer image with
`streamLayeredImage`; it builds inside this container under the no-sandbox
nixbld setup too. Stream size 402 MB uncompressed (the relocated
`/opt/store` closure; `/nix` is empty, the volume is the store).
Checked by unpacking the tarball: Entrypoint/Cmd as the Containerfile,
PATH profile-first then `/usr/local/bin` and `/opt/bootstrap/bin`, SHELL
nu, `/etc/passwd` with root (nu) and nixbld1-8, nix.conf, `/etc/shells`,
gitconfig, the six shims, `/opt/homun`, managed-settings, and
bash, curl, git, nix, nu and the four compiled tools under `/opt/store`.
Not run under podman yet.

## Step 2: what switching needs

- The user runs the first `just build-nix` and a test container (mechanic first)
  on the host; then `just build`/`just update` and run.nu use the image tag
  `claude-nix` (run.nu hard-codes `claude`), with the Containerfile as
  fallback.
- Offline first start lacks runit, gh, jq and notify-send (Debian had
  them; here they come only from the tools profile): services do not start
  until the network is back. Add `runit` (and maybe `gh`, `jq`) to the
  bootstrap env if that matters.
- python3 is absent from both images; the shims still rely on the profile.
- Nix version: the image's nix (nixpkgs) differs from Debian's `nix-bin`
  writing the shared `/nix/var/nix/db`; switch the Manager and mechanic
  together and test on the existing volume.
- The relocation rewrites `/nix/store/` strings in every file; a binary
  with a compressed or hashed embedded path would break silently. Smoke
  test `nix`, `git` (https), `curl` and `nu` in the first container.
- `aarch64-linux`: `lib64` link and the static tools are untested there.

## Risks

- First-boot network dependence (cache.nixos.org, nixpkgs, claude.ai); a
  failed install must not stop boot (the entrypoint already tolerates it).
- nix.conf drift between image and an older volume's profiles; pin nix.conf
  in the image and test on a fresh and an old volume.
- The mechanic container shares the volumes: same image build and nix.conf,
  or two Nix versions write the same `/nix/var/nix/db`.
- Copy-up seeding is not atomic; a half-seeded volume is not detected.

## Decisions (the user, 2026-11-01)

1. Image size: small. The Nix store is the persistent `claude-nix` volume,
   so the image ships an empty store; tools are installed into the volume
   at first start (the #85 mechanism). Approach 1 above.
2. Built on the host: `just build` runs the flake's image output and
   `podman load`s it; the host has Nix.
3. Offline first start: the image carries a minimal working shell, curl and
   git outside `/nix`, so a boot without network still gives a usable
   container; Nix tools arrive when the network is back.
4. The Rust and Go tools move into the flake now (one lock; no multi-stage
   builds in the new image).

## Open questions for the user (answered above; kept for the record)

1. Image size: is ~1 GB acceptable, or must it stay near today's?
2. Where is the image built: on the host (needs Nix there) or inside the
   Manager container?
3. May a first start without network fail hard, or must the image carry a
   minimal working shell and git?
4. Rust and Go tools: into the tools flake now, or keep the multi-stage
   builds until Option B is proven?

Not verified: Podman copy-up into an empty named volume on `/nix`; building
the image under our no-sandbox nixbld setup; `nixos/nix` details are from
`docker.nix`, not the Docker Hub image.
