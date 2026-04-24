# nanoclj-zig Zig 0.16 migration ledger

Last updated: 2026-04-24
Repo head: `f894a1b9d39c0389090c4fa26691884052a19020` (main)

## Pinned versions

- **zig**: `0.16.0` (via `mlugg/setup-zig@v2`, pinned in `.github/workflows/ci.yml`)
- **zig-syrup sibling**: cloned from `main` (previously pinned to `radical/zig-0.16.0-native`; that branch was deleted when zig-syrup#5 squash-merged, and the CI hardcoding was fixed in the same session).

## Landed via merge train 2026-04-24

| PR   | Summary                                             |
|------|-----------------------------------------------------|
| #22  | chore(zig): pin 0.16.0 + CI matrix (squash-merged) |

Follow-up commit on main: `f894a1b9d39c0389090c4fa26691884052a19020` — ci: stop cloning deleted `radical/zig-0.16.0-native`; clone zig-syrup default branch instead.

## Open PRs

| PR  | Disposition | Next action                                                                                                                  |
|-----|-------------|------------------------------------------------------------------------------------------------------------------------------|
| #21 | PATCH       | update-branch (2026-04-24) queued merge-from-main on fork `danielesiegel/nanoclj-zig`; CI will run under the fixed workflow. |
| #23 | DEFER       | Author-draft. Base retargeted to `main`; conflict with landed #22 squash expected. Leave for author to rebase.              |

## Cross-repo assumptions

- CI clones `https://github.com/plurigrid/zig-syrup.git` default branch (`main`). Any breaking API change in zig-syrup main will break this CI; keep zig-syrup main invariant against `zig 0.16.0`.

## Verification commands

```
zig fmt --check .
zig build
zig build test --summary all
```

All must pass on ubuntu-latest and macos-latest under CI matrix.
