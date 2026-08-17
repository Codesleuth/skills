# Contributing

Contributions are welcome — new skills, fixes to existing ones, better documentation.

There is one condition, and it is not negotiable: **everything you contribute must be
free of any license obligation, and you must be donating it outright.** The rest of this
page explains exactly what that means, because it rules out some things people do without
thinking about it.

## What you can contribute

Only work that is yours to give away with no strings attached:

- Something you wrote yourself, from scratch.
- Something taken from a source that is genuinely royalty-free and unrestricted — public
  domain, CC0, or equivalent. "Free to use" is not the same thing; a permissive license
  like MIT or Apache-2.0 still carries obligations (attribution, notice files), and those
  obligations make it unsuitable here.

If you cannot say where a piece of your contribution came from, do not include it.

## Using an LLM to help

Using Claude or any other model to help write a skill is fine — this repository is built
that way. What is not fine is contributing model output that was derived from restrictively
licensed material: code a model reproduced from a GPL project, prose lifted from
documentation with a license attached, a skill that is essentially someone else's work
re-worded.

If you asked a model to "do it like project X does", or it handed you back something you
recognize from a real codebase, that is the case this rule is about. Check it, and leave it
out if you are unsure.

## Donation of ownership

By opening a pull request you are donating your contribution. You keep no ownership of it,
you assert no license over it, and you make no claim on it afterwards. Once merged, it is
part of this repository under [the MIT license](LICENSE) and is maintained here.

You must have the right to do that. If your employer owns your output, or the work was done
under a contract that assigns it elsewhere, then it is not yours to donate — get that sorted
out first.

Opening a pull request is how you confirm all of the above. There is no CLA to sign and no
form to fill in; the act of submitting is the affirmation.

## Practical notes for a new skill

Build it with the [`skill-creator`](https://github.com/anthropics/skills/tree/main/skills/skill-creator)
skill rather than writing the files by hand — ask Claude to use it. It walks you through
the design, scaffolds the layout, and can measure how reliably the finished skill triggers.
Skills here are expected to have been made that way.

The conventions it needs to respect in this repository:

- One directory per skill under `skills/`, named the same as the skill.
- A `SKILL.md` with `name` and `description` frontmatter. The description is what decides
  whether the skill triggers, so write it for matching, not for marketing — name the
  phrases a user would actually say.
- No `LICENSE` file inside the skill directory. Licensing is handled once, at the root.
- A `README.md` in the skill directory if a human needs setup instructions (tools to
  install, credentials, limits worth knowing before running it).
- Put executable helpers in `scripts/` and background material in `references/`.
- Say what the skill will *not* do. A skill that is honest about its limits is more useful
  than one that implies it handles everything.

## Raising a problem

If something is broken or a skill behaves badly, open an issue describing what you asked
for, what happened, and what you expected. A transcript excerpt is worth more than a
description of it.
