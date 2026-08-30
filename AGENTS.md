# Repository instructions for AI coding agents

## Scope and evidence

- Treat the current checkout, target commit, tests, and remote checks as the source of truth. Do not infer current behavior from an older review or conversation.
- Keep `llm4cj` provider-neutral. Applications own HTTP clients, credentials, retries, endpoint selection, model catalogs, and agent loops. This repository owns canonical wire semantics, strict encoding and decoding, bounded framing, and deterministic errors.
- Preserve unrelated work. Inspect the workspace before editing, and do not discard, rewrite, move, commit, or publish changes that belong to another task or agent.
- Distinguish static inspection, local checks, coverage, remote CI, provider smoke, and release evidence. Report only the evidence that actually ran for the exact commit.

## Development workflow

- Work from `main` on a short-lived branch named `<type>/<kebab-case>`, where `type` is `feat`, `fix`, `docs`, `test`, `refactor`, `ci`, `build`, or `chore`.
- Open pull requests directly against `main`. Do not create or revive a long-lived `dev` integration branch.
- Use Conventional Commit syntax for commits and pull-request titles.
- Keep each pull request focused. Keep behavior and its regression tests together; separate unrelated documentation, generated output, or mechanical cleanup when practical.
- Prefer GitButler for version-control operations when it is available. Do not push, open a pull request, merge, or alter repository settings unless the user explicitly requests that external change.
- Never commit agent-local state or instructions from `.agents/`, `.claude/`, or `.codex/`.

## Implementation rules

- Fail closed when provider data is malformed or when valid provider semantics cannot be represented without loss. Do not silently drop fields, reorder blocks, invent defaults, or turn truncation into success.
- Keep fixed and streamed decoding canonically equivalent for every supported semantic path.
- Validate complete requests before producing sendable bytes. Explicit options must be encoded exactly, resolved as a requirement, or rejected.
- Bound provider-controlled memory, event counts, nesting, and diagnostic retention before allocation or externally visible semantic emission.
- Do not expose provider-native replay payloads as an unrestricted JSON escape hatch.
- Use `apply_patch` for hand edits. Prefer `rp-rg`, `rp-sed`, `rp-awk`, `rp-grep`, and `rp-find` when their raw command semantics are needed.

## Validation

- Run `scripts/check.sh` for source, API, fixture, documentation, build, and test changes.
- Run `scripts/coverage.sh` when executable Cangjie lines or branches change.
- Run `python3 scripts/check_contract.py` when public declarations, errors, fixtures, or contract snapshots change.
- Add deterministic regression coverage for every corrected protocol path. Provider network calls are advisory evidence and must not replace offline fixtures.
- If a command cannot run, identify the exact missing evidence. Do not describe an unrun gate as passing.

## Pull-request metadata

- Declare exactly `Risk: routine` or `Risk: high` in the pull-request body.
- Routine changes must close an open repository issue or include `Issue: N/A: <specific reason>`.
- High-risk changes must close an open same-repository issue. Sensitive workflow, source, contract, release, and modified-test paths are automatically high risk.
- High-risk changes require a repository writer to comment `/land <full-40-character-head-sha>`. Any new push invalidates the old confirmation.
- Dependabot is exempt from the issue requirement, but not from high-risk landing confirmation.

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [trunk-based development ADR](docs/adr/0001-trunk-based-development.md) for the human-facing workflow.
