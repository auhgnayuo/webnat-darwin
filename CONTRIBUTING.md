# Contributing

## Releasing a version

1. Move items from `CHANGELOG.md` **Unreleased** into a dated `[x.y.z]` section, then add a fresh **Unreleased** heading if needed.
2. Bump `Sources/Webnat/Version.swift` and `Webnat.podspec` (`s.version`) to the same semver.
3. Update installation snippets in `README.md` / `README_CN.md` if you pin an explicit version in examples.
4. Commit and push, then create a Git tag that matches `s.version` (for example `1.0.3`).

## CocoaPods checks

- **Before tagging:** from the repo root, run `pod lib lint Webnat.podspec` to compile the pod against your **local** tree.
- **After the tag is on the remote:** `pod spec lint Webnat.podspec` fetches `s.source` from Git; it only passes once that tag exists on the server.

Consumers can depend on the podspec via `:git` and `:tag`; no CocoaPods trunk push is required.
