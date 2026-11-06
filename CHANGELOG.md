# Changelog

## Unreleased

### Fixed

- Bound initial-release history to 500 commits, fail invalid release tags, and
  support explicit normalized legacy-version recovery with verified ancestry.
- Refuse all release writes when a live version milestone still has open issues or PRs.
- Prevent historical replay from creating or reopening a stale next patch.
- Repair milestone dates from valid deterministic release/tag timestamps.

### Added

- Explicit PR milestone target selection and enforcement; open PRs cannot target closed versions.
- Release publication, tag push, and manual recovery caller example.
- Offline regression coverage for release and milestone guard behavior.
