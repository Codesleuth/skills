# CLAUDE.md

Agent skills for Claude Code, one directory each under `skills/`. No build, tests, or
CI — verification is manual.

- **Adding a skill:** build it with the `skill-creator` skill rather than hand-writing the
  files, and add a row to the `## Skills` table in the root `README.md`.
- **No `license:` in SKILL.md frontmatter and no `LICENSE` file in a skill directory** —
  the root MIT `LICENSE` covers everything.
- **Everything here is written from scratch.** Per `CONTRIBUTING.md`, a contribution must
  carry no license obligation at all, which rules out permissive licenses as well. Read
  `anthropics/skills` (Apache-2.0) for architectural patterns and ideas if it helps, but
  do not copy its prose or code in: stripping the license header and the frontmatter does
  not make a derivative work donatable.
- **Bundled scripts are bash, committed `chmod +x`.** `apply-pr-feedback` deliberately
  avoids Python and standalone `jq` — `gh` has a jq engine behind `--jq`. Keep new
  scripts equally install-free.
- Prose wraps at ~90 columns; tables, frontmatter, and links run long.
- **`gh` fails inside the Claude Code sandbox** — no network hosts are allowed, and gh
  misreports it as `The token in keyring is invalid`, which the skill's own README tells
  you to fix with `gh auth refresh`. Re-run with the sandbox disabled before believing
  auth is broken.
