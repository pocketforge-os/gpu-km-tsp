# gpu-km-tsp

PocketForge-owned PowerVR DDK 1.19 kernel module fork for the GE8300 (TrimUI Smart Pro A133). Signed source fork, NOT a blackbox — the 2026-06-14 pivot moved the KM off vendor blob to owned source. Cross-repo doctrine lives in [`pocketforge-os/mission-control`](https://github.com/pocketforge-os/mission-control); this file is orientation only.

## Session startup + working norms

Run `bd prime` (auto-injected), `bd dolt pull`, register + background your pf-wall listener, `bd update <id> --claim`, and edit in a fresh `pf-wt create <bead-id> --repos gpu-km-tsp[,…]` worktree — never in `/home/matt/gpu-km-tsp` directly. Full checklist: [mission-control CLAUDE.md](https://github.com/pocketforge-os/mission-control/blob/master/CLAUDE.md); worktree/branch→PR→merge norm: [mission-control git-workflow rules](https://github.com/pocketforge-os/mission-control/blob/master/.claude/rules/git-workflow.md). Every change is a `<bead-id>` branch → PR → merge; no straight-to-default pushes.

## Shared Claude Code substrate

`.claude/settings.json` enables the shared `pf@pocketforge` plugin ([pocketforge-os/claude-plugins](https://github.com/pocketforge-os/claude-plugins)): skills (`/build-image`, `/close-bead`, `/file-bead`, `/flash`, `/kickoff`, `/plan-doc`, `/screen-check`, `/serial-review`), custom agents (`log-triage`, `researcher`, `screen-reviewer`), enforcement hooks (PreToolUse deny+redirect, Stop DoD gate, InstructionsLoaded audit).

## Repo-specific gotchas

- **Do NOT hand-build the KM — use the `pf build` path** via [`/build-image`](https://github.com/pocketforge-os/claude-plugins/blob/main/plugins/pf/skills/build-image/SKILL.md) → `pocketforge-automation/scripts/build-owned-image.sh`. `platform.lock` resolves this repo's SHA; the build runs in the pinned `pocketforge/build:10.3-2021.07-bookworm` container against the source-forked kernel headers.
- **Owned KM + STOCK user-mode blobs is the design.** The UM DDK `.so` set stays in the `blobs` repo (closed, provenance-pinned, distributed via `vendor-manifest`); THIS repo owns only the kernel-mode side. Prefer an owned-source fix (kernel / KM / `dc_sunxi`) over patching a closed UM blob — a KM tweak covers most of what a blob patch would. See [mission-control provenance rules](https://github.com/pocketforge-os/mission-control/blob/master/.claude/rules/provenance.md).
- **BVNC alignment matters.** The KM is built for a specific `BVNC` (currently `22.102.54.38` — DDK 1.19.6345021). If the UM `.so`s ship a different BVNC (from a fresh `blobs` drop), dmesg will refuse to bind and the cube won't render. Check `blobs/tsp/<bvnc>/PROVENANCE.md` first.
