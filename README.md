![Codesleuth skills — agent skills for Claude Code](assets/banner.svg)

Agent skills for [Claude Code](https://claude.com/claude-code). Each one is a self-contained
folder: instructions in `SKILL.md`, plus any scripts and reference material it needs.

## Install

One command, nothing to clone:

```bash
npx skills add Codesleuth/skills
```

That fetches this repo and installs the skills into the current project: the files land in
`.agents/skills/`, `.claude/skills/` is symlinked to them, and `skills-lock.json` records
what you took. Everything else is a variation on the same line:

```bash
npx skills add Codesleuth/skills -g                   # every project, not just this one
npx skills add Codesleuth/skills --skill review-pr    # take a single skill
npx skills add Codesleuth/skills --list               # see what's here, install nothing
```

Afterwards, `npx skills update` pulls newer versions, `npx skills list` shows what you have,
and `npx skills remove` takes one back out. All you need is Node on your `PATH` — the
[`skills` CLI](https://www.skills.sh/) runs straight from `npx` and is never installed.

Claude picks a skill up on the next session. You don't invoke it by name — ask for what you
want in plain language and the matching skill triggers.

## Skills

| Skill | What it does |
|---|---|
| [`apply-pr-feedback`](skills/apply-pr-feedback) | Applies GitHub PR review feedback end to end — fixes the unambiguous comments one commit each, pushes, drives CI to green, then replies with the commit hash and resolves the thread. Judgment calls are collected into a summary instead of being acted on. |
| [`review-pr`](skills/review-pr) | Reviews the changes a GitHub pull request makes, reading enough of the surrounding code to judge them correctly, then publishes it as one review — inline comments on the lines they're about, plus a summary that approves, comments, or requests changes. Reads the code; never runs it or changes it. |

Each skill's README covers the tools it needs and what it will and won't do, and its
`LICENSE.txt` covers the terms you take it under.

## Other ways to install

### With Tessl

[Tessl](https://tessl.io) is a package manager for agent context — it pins what you install
and tracks it in a manifest. It reads this repo straight from GitHub, no registry entry
needed:

```bash
npx @tessl/cli install github:Codesleuth/skills --agent claude-code
```

The skills unpack into `.tessl/plugins/`, get symlinked into `.claude/skills/` under a
`tessl__` prefix, and are pinned to an exact commit in `tessl.json`. Add `--skill review-pr`
for a single skill, or `--global` to install into `~/.tessl/` instead. In a project Tessl
hasn't seen before it runs `tessl init` first, which also writes `AGENTS.md`, `CLAUDE.md`,
`.tessl/RULES.md`, and an `.mcp.json` pointing at the Tessl MCP server — worth knowing
before you run it in a repo that already has its own. That server expects a real `tessl`
binary on your `PATH` (`brew install tesslio/tap/tessl`); `npx` alone is enough to install
the skills.

One caveat: Tessl's packaging drops the executable bit, and both skills run their bundled
scripts directly. Restore it after installing, or they fail with `permission denied`:

```bash
chmod +x .tessl/plugins/Codesleuth/skills/skills/*/scripts/*.sh
```

### From a clone

If you'd rather track the repo yourself, clone it and symlink the skills you want. A symlink
means `git pull` updates the skill in place — with a copy you'd have to remember to re-copy
it.

```bash
git clone https://github.com/Codesleuth/skills.git ~/src/codesleuth-skills

# available everywhere
mkdir -p ~/.claude/skills
ln -s ~/src/codesleuth-skills/skills/apply-pr-feedback ~/.claude/skills/apply-pr-feedback

# or just in one project
ln -s ~/src/codesleuth-skills/skills/apply-pr-feedback /path/to/project/.claude/skills/apply-pr-feedback
```

Give `ln -s` an absolute path for the target — a relative one is resolved from the link's
own directory, not from where you ran the command.

## Contributing

Contributions are welcome, with one condition: they must be free of any license obligation
and donated outright. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

Licensing lives with each skill, not with the repository. Read the `LICENSE.txt` in a skill's
folder for the terms that apply to it — its `SKILL.md` frontmatter points at the same file.
There is no repository-wide license, so check the skill you are actually taking.
