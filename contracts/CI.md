# Test gates / runner setup

- Web: PR/push run `npm test` (type checks and runtime tests), contract verification, then build.
- Electron: PR/push run all tests on macOS, including the real renderer tests. Web/Electron interop is a
  separate cross-repository gate, not silently skipped inside the standalone unit suite.
- Darwin: PR/push run `scripts/test.sh` and compile the iOS example. macOS tests include WebKit substitutes
  and JavaScriptCore; this is not a claim of iOS UI/device coverage.
- Android: PR/push run library/example tests, virtual-clock/race tests and Robolectric lifecycle cases on
  API 28/36, then compile instrumentation tests. Device execution is still a separate requirement.
- OHOS: hosted CI verifies contract digests. The full SDK job requires an isolated self-hosted macOS runner
  labeled `webnat-ohos-sdk`, with DevEco SDK, `hvigorw`, Python 3 and Node configured. Configure the
  `ohos-tests` environment with required approval. Never run untrusted fork code automatically on a
  persistent SDK host. Fork PRs require maintainer review and an approved manual SDK run.

## Manual releases / drift checks

All platforms are published manually by maintainers. GitHub Actions only verifies tests, builds and
contracts; pushing a tag does not publish the Web npm package or the Android Maven artifact.
Run the relevant repository's test suite before publishing, and run the cross-repository contract / real
interop workflow against matching refs/tags for a coordinated release candidate.

The cross-repository workflow remains manually runnable and scheduled weekly. Its native ref defaults to
`main`. Checkout uses the normal read-only GitHub token and assumes public repositories; private
repositories need an appropriately scoped read token. Publishing credentials stay outside these test
workflows. Removing automatic publishing does not remove local npm / Gradle publishing capabilities.

This work changes workflow files only: it does **not** provision runners, configure repository branch
protection, approve environments, execute hosted CI, or publish packages.

Set branch protection to require each repository's Test jobs after these workflows have run successfully.
A workflow existing in git is not proof that a required status check or a self-hosted runner is operational.
