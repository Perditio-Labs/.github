# Changelog

## Unreleased

### Fixed

- Bound initial-release history to 500 commits, fail invalid release tags, and
  support explicit normalized legacy-version recovery with verified ancestry.
- Prevent historical replay from creating or reopening a stale next patch.
- Repair milestone dates from valid deterministic release/tag timestamps.

### Added

- Explicit PR milestone target selection and enforcement.
- Release publication, tag push, and manual recovery caller example.
- Offline regression coverage for release and milestone guard behavior.
