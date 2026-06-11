## What
<!-- 
Clear, concise summary of the change.
Include whether this PR affects:
- Flutter UI
- Business logic
- Router‑push logic
- Cryptography or key handling
- Network or certificate‑pinning behaviour
- Build system / reproducibility
-->

## Why
<!-- 
Explain the motivation.
Reference security, correctness, performance, UX, or reproducibility goals.
If fixing a bug, describe root cause at a high level.
-->

## How to Test
<!-- 
Provide deterministic, step‑by‑step instructions.
Include:
- Commands to run (flutter test, integration tests, etc.)
- Expected behaviour before vs after
- Any platform‑specific notes (Android physical device, AVD)
- Security‑sensitive validation steps (e.g., ensure no secrets logged, router‑push mock behaviour)
-->

## Security Considerations
<!-- 
MANDATORY for any PR touching:
- WireGuard key generation
- PIA authentication flow
- Router SSH logic
- Certificate pinning
- Dependency updates
- Any code that handles secrets or ephemeral data

Describe:
- Attack surface changes
- How sensitive data is protected
- Whether logs were reviewed for accidental leakage
- Whether new dependencies were security‑reviewed
-->

## Reproducible Build Impact
<!-- 
If this PR affects build scripts, Gradle, lockfiles, or GitHub Actions:
- Confirm all dependencies remain pinned
- Confirm lockfiles were regenerated where required
- Confirm workflows use pinned SHAs
-->

## Related
- Issue: #123
- Jira: ABC‑456
<!-- Add links to design docs, threat models, or related PRs if applicable -->

## Checklist
- [ ] Tests added/updated (unit + failure‑mode tests)
- [ ] `flutter analyze` passes
- [ ] `flutter test --coverage` passes
- [ ] Lockfiles updated (if dependencies changed)
- [ ] No secrets logged (checked manually)
- [ ] New dependencies reviewed for security impact
- [ ] GitHub Actions SHAs updated (if workflows changed)
- [ ] UI screenshots attached (if UI changes)
- [ ] Router‑push logic tested using mocks only (no real SSH)
- [ ] Documentation updated (README / DEVELOPMENT / SECURITY.md)
