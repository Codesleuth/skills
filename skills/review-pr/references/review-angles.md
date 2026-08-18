# Review angles

The catalogue behind Step 4 of `SKILL.md`. Each angle is a different question to ask the
same diff. Read this when you are about to hunt, and work through the angles that apply.

A single linear read of a patch finds the bugs that look like bugs. The ones that ship are
the ones that look fine in the hunk: the guard that quietly disappeared, the caller two
files away, the footgun that is only a footgun in this language. Each angle below exists
because it catches a class of defect the linear read reliably walks past.

## Contents

- [How to run an angle](#how-to-run-an-angle)
- [Correctness angles](#correctness-angles)
  - [1. Line by line, with the enclosing function](#1-line-by-line-with-the-enclosing-function)
  - [2. What the diff removed](#2-what-the-diff-removed)
  - [3. Across the call graph](#3-across-the-call-graph)
  - [4. Language footguns](#4-language-footguns)
  - [5. Wrappers, proxies, and delegation](#5-wrappers-proxies-and-delegation)
  - [6. State, concurrency, and failure paths](#6-state-concurrency-and-failure-paths)
  - [7. Tests as evidence](#7-tests-as-evidence)
- [Language footgun tables](#language-footgun-tables)
- [High-risk domains](#high-risk-domains)
- [Quality angles](#quality-angles)
- [Conventions the repo writes down](#conventions-the-repo-writes-down)
- [The sweep list](#the-sweep-list)

## How to run an angle

**One angle at a time, and let each one finish.** The value comes from the angles being
independent. If you carry the conclusion "I already checked that function" from angle 1
into angle 3, angle 3 stops being a second look and becomes an echo of the first.

**Do not filter while you hunt.** An angle's job is to produce candidates, not verdicts.
Judging each candidate as it appears is what makes a review shallow: the plausible-but-
uncertain finding is exactly the one that turns out to be real, and it is the first one
self-censorship throws away. Write it down, then decide later, in one deliberate pass
(Step 5), with the whole list in front of you.

**Record collisions rather than resolving them.** Two angles flagging the same line for
different reasons is a signal, not a duplicate. Deduplication happens once, afterwards,
and only for genuinely identical findings — same defect, same location, same reason.

**Give each angle a budget and stop there.** Around eight candidates per angle is enough
on any realistic PR. Past that you are padding, and padding is what buries the real
findings.

Each candidate wants four things recorded, because these are what Step 5 needs to judge it
and what the inline comment is built from:

| Field | What it holds |
|---|---|
| `file` / `line` | Where the comment will anchor — a line this PR changed |
| `summary` | One sentence: what is wrong |
| `failure scenario` | Concrete inputs or state → the wrong output, crash, or cost |
| `evidence` | The line, or the other file's line, that proves it |

The failure scenario is the load-bearing one. "This might not handle nulls" is a worry;
"`Load` returns `nil, nil` when the config file is absent, so line 42 dereferences nil and
panics on first boot" is a finding. If you cannot write the concrete version, you have not
finished thinking — either finish, or let it go.

## Correctness angles

### 1. Line by line, with the enclosing function

Read every hunk line by line, then read the **whole enclosing function** for each hunk, in
the file as the PR leaves it. The unchanged lines are how you judge the changed ones: a nil
check twenty lines up, or its absence, is what decides whether the new line is safe.

Where an unchanged line turns out to be the real problem, the finding still has to anchor
to a line the diff shows — a context line inside a hunk qualifies, a line the diff never
displays does not. If it cannot anchor, it belongs in the summary rather than as an inline
comment. A change that re-exposes an old bug, moves it onto a live path, or was supposed to
fix it and didn't is a finding about the change; a bug the PR merely happens to sit near is
not.

For each line, ask the question that actually finds things: *what input, state, timing, or
platform makes this line wrong?* Not "is this line good" — that question has no answer.

The recurring answers:

- **Inverted or wrong condition** — `&&` where `||` was meant, a negation dropped in a
  refactor, a De Morgan rewrite that changed meaning.
- **Off-by-one and boundaries** — `<` vs `<=`, empty input, single-element input, the last
  element, an index computed from a length that changed above.
- **Null / undefined / zero-value dereference** — including the falsy-zero trap, where a
  legitimate `0`, `""`, or `false` takes the "missing" branch.
- **Missing `await`, unchecked error, swallowed exception** — a `catch` that logs and
  continues, leaving the caller to act on a half-built value.
- **Copy-paste with one variable unswapped** — the classic: two near-identical blocks where
  the second still references the first's variable.
- **Unescaped metacharacters** — a user string interpolated into a regex, a glob, a path, a
  format string, or a query.
- **A value used before it is assigned** on one branch, or assigned twice with the first
  write dead.

### 2. What the diff removed

For every line the diff **deletes or replaces**, name the invariant or behaviour it
enforced, then go find where the new code re-establishes it. If you cannot find it, that is
a candidate.

This is the highest-yield angle and the one reviewers skip most, because deletions read as
progress. Additions announce themselves; a guard that is simply gone announces nothing.

What to look for in the minus lines:

- A validation, bounds check, nil check, or permission check that no longer runs.
- An error path collapsed into a success path — an `if err != nil` that became a bare call.
- A narrowed check: `validate(input)` replaced by `validate(input.name)`.
- A `defer`/`finally`/`ensure` that closed, unlocked, or rolled back something.
- A default value, retry, timeout, or cap that changed or vanished.
- A deleted test. Name what it covered and find its replacement. "The test was flaky" is a
  reason to fix the test, not to lose the coverage.
- A comment that documented a non-obvious constraint, removed while the constraint stayed.

### 3. Across the call graph

The change is local; the damage is at the boundary. For every function, method, type, or
constant the diff changes, search the repo at the PR ref for its name (`git grep -n "name" refs/review-pr/412`) and check both
directions.

**Callers** — does the change break any call site?

- A new precondition the caller does not satisfy.
- A changed return shape, an added error return, a nullable where a value was guaranteed.
- A new exception or panic on a path that previously could not fail.
- An ordering or timing dependency: the caller now has to do something first.
- A parameter added with a default, where one caller genuinely needs the non-default.
- Behaviour that changed silently for existing callers — same signature, different result.
  These are the worst, because nothing fails to compile.

**Callees** — does a parallel change in the same PR make an existing call unsafe? Two
edits that are each correct alone can be wrong together, and only the review sees both.

**Serialised and persisted boundaries** count as call sites: database columns, cached
payloads, queue messages, config files, API responses, feature-flag names. Old data written
by the old code has to still be readable by the new code, and during a rolling deploy both
versions run at once.

### 4. Language footguns

Scan the diff for the classic traps of its language and framework. See the
[tables below](#language-footgun-tables). Only flag an instance the diff actually
introduces or moves onto a live path.

### 5. Wrappers, proxies, and delegation

When the PR adds or modifies a type that wraps another — a cache, proxy, decorator,
adapter, retry layer, instrumented client — check two things.

**Every method routes to the wrapped instance, not back through a registry, session, or
global.** A caching provider holding a `delegate` field that resolves an ID via
`session.get(...)` instead of `delegate.get(...)` re-enters its own cache: infinite
recursion, a stack overflow, or a lookup that silently returns the wrapper's own stale
entry. This one is easy to miss because the wrong call reads perfectly naturally.

**The wrapper forwards everything the callers actually use.** A partial wrapper compiles
in a duck-typed or interface-satisfying language and then loses a method's behaviour at
runtime — `close()` that doesn't close the inner resource, `Len()` that reports the
wrapper's own empty state, an iterator that ends early.

Also: does the wrapper preserve the wrapped thing's error types, context/cancellation,
timeouts, and thread-safety guarantees? A wrapper that catches and re-raises as a generic
error destroys the caller's ability to branch on the cause.

### 6. State, concurrency, and failure paths

- **Shared mutable state** newly reachable from more than one goroutine, thread, request,
  or event-loop turn. A field promoted from local to struct member is the usual route.
- **Lock scope** — narrowed during a refactor, or a check and the action it authorises no
  longer under the same lock (TOCTOU).
- **Ordering** — two operations that must both happen, with no transaction or compensation
  if the process dies between them.
- **Idempotency and retries** — a retry added around something that is not safe to run
  twice (a charge, an email, an append).
- **Resource lifetime** — anything opened, locked, or subscribed on a path that can return
  or throw before it is released.
- **Partial failure** — what state is left behind when step 3 of 5 fails? Is it recoverable
  by re-running?
- **Unbounded growth** — a cache, map, slice, or list with no eviction and a key derived
  from user input.

### 7. Tests as evidence

Tests in a PR are a claim about behaviour. Check the claim.

- Does the new test actually exercise the new behaviour, or does it assert that a mock was
  called? A test that would still pass with the implementation gutted is not coverage.
- Does a bug fix carry a test that fails without the fix? If not, say so — that is the test
  that stops the bug coming back.
- Does an existing test still cover what its name claims after the change, or did the
  change make the assertion vacuous (comparing a value to itself, asserting on an empty
  collection, a loop that runs zero times)?
- Are the interesting cases there — empty, one, many, boundary, error path — or only the
  happy one?
- Setup/teardown symmetry: everything created is cleaned up, on the failure path too.
- Determinism: real clocks, real network, real randomness, `hash()` or map-iteration order,
  or test-to-test ordering dependencies are how a suite becomes flaky.

## Language footgun tables

**JavaScript / TypeScript**

| Trap | What goes wrong |
|---|---|
| `if (x)` on a number or string | `0` and `""` take the "missing" branch — use `!= null` or `??` |
| `==` coercion | `"0" == false`, `null == undefined`, `[] == ""` all true |
| Missing `await` | The function returns a pending promise; the `try/catch` around it catches nothing |
| Floating promises | An unawaited async call rejects into an unhandled rejection, sometimes fatal |
| `forEach` with an async callback | Runs them all at once and awaits none of them |
| `this` in a callback | Lost unless bound or an arrow function |
| Object/array default in a shared scope | One mutation leaks to every user of it |
| `JSON.parse` on untrusted input | Throws; also `__proto__` pollution when merging the result |
| `Number` precision | `0.1 + 0.2 !== 0.3`; IDs beyond `2^53` lose digits when parsed as numbers |
| `Array.sort()` without a comparator | Sorts lexicographically: `[9, 10]` → `[10, 9]` |
| TypeScript `as` | An assertion, not a check — silences the compiler without validating anything |

**Python**

| Trap | What goes wrong |
|---|---|
| Mutable default argument | `def f(x=[])` — the list persists across every call |
| `dataclasses.field` vs a bare default | A bare mutable default is shared; and the default is evaluated once, at class definition |
| Late-binding closures | Every lambda in a loop sees the final loop value; bind with a default arg |
| `except:` / `except Exception` | Swallows `KeyboardInterrupt`, `SystemExit`, and real bugs |
| Truthiness on `0`, `""`, `[]`, `None` | Same conflation as JS — use `is None` |
| `hash()` of a `str` | Salted per process; never persist it or rely on ordering derived from it |
| Shallow copy | `dict(d)` / `list(l)` copy one level; nested values stay shared |
| Generator consumed twice | The second pass sees nothing |
| Integer division / `round` | `round` is banker's rounding: `round(0.5) == 0` |
| `datetime.now()` naive | No timezone; comparing it to an aware datetime raises |
| f-string in a SQL or shell string | Injection |

**Go**

| Trap | What goes wrong |
|---|---|
| Write to a nil map | Panic; reads are fine, which hides it in testing |
| Loop-variable capture (pre-1.22) | Every goroutine or closure sees the last element |
| `defer` inside a loop | Nothing releases until the function returns |
| Shadowed `err` with `:=` | The outer `err` stays nil and the failure is lost |
| Nil interface vs nil pointer | A nil `*T` stored in an interface is non-nil — `err != nil` is true |
| Slice aliasing after `append` | Sub-slices share backing arrays until a reallocation, then silently stop |
| Unchecked type assertion | `v.(T)` without the comma-ok panics |
| Context ignored | A cancelled request keeps working |
| `time.After` in a loop | The timer is not collected until it fires |

**Rust**

| Trap | What goes wrong |
|---|---|
| `unwrap` / `expect` on a fallible path | A panic where an error should propagate |
| Integer overflow | Wraps in release, panics in debug — behaviour differs by profile |
| `as` casts | Silent truncation; prefer `try_into` |
| Holding a lock across `.await` | Deadlock, or blocking the executor |
| `Rc`/`Arc` cycles | Leaked memory with no destructor run |

**Java / Kotlin / C#**

| Trap | What goes wrong |
|---|---|
| `equals`/`hashCode` changed on one side only | Objects vanish from hash-based collections |
| Autoboxing and `==` on boxed types | Reference comparison outside the small-integer cache |
| Mutable object used as a map key | Mutating it makes the entry unreachable |
| `Optional` unwrapped without a check | Same NPE, further from the cause |
| `async void` (C#) | Exceptions escape the caller entirely |
| `ConfigureAwait` / captured sync context | Deadlock in a UI or legacy ASP.NET context |
| Kotlin platform types from Java | `!!` on something Java can legitimately return null for |

**C / C++**

| Trap | What goes wrong |
|---|---|
| Buffer arithmetic and `strcpy`-family calls | Overflow; `snprintf` truncation not checked |
| Signed overflow, shift by width | Undefined behaviour the optimiser may exploit |
| Use-after-free / dangling reference | Especially from a returned reference to a local or a temporary |
| Iterator invalidation | Any insert into a `vector` invalidates iterators and pointers |
| Mismatched allocation | `new[]` freed with `delete`, `malloc` freed with `delete` |

**Ruby / PHP**

| Trap | What goes wrong |
|---|---|
| Ruby: only `nil` and `false` are falsy | `0` and `""` are truthy — the opposite conflation |
| Ruby: `dup` is shallow; frozen-string differences | Mutation leaks through shared references |
| PHP: `==` vs `===` | Numeric-string coercion; `"abc" == 0` on old versions |
| PHP: `in_array` without strict mode | Same coercion, in a security check |

**Shell**

| Trap | What goes wrong |
|---|---|
| Unquoted `$var` | Word-splits and globs; breaks on spaces and empty values |
| No `set -euo pipefail` | A failing command in the middle keeps going |
| Exit code of a pipeline | Only the last command's status, unless `pipefail` |
| `[ $x = y ]` with an empty `$x` | Syntax error — quote it or use `[[ ]]` |
| `rm -rf "$dir/"` with `dir` unset | Deletes from `/` |
| Parsing `ls` | Breaks on any unusual filename |

**SQL and data**

| Trap | What goes wrong |
|---|---|
| String-built query | Injection; use parameters, always, including for `IN` lists |
| `NULL` comparison and `NOT IN` | `NULL` in the set makes the whole predicate null — no rows |
| Migration adding a `NOT NULL` column without a default | Locks or fails on a non-empty table |
| Index dropped, renamed, or never added for a new query | A full scan under production volume |
| Missing transaction around multi-statement writes | Partial state on error |
| `SELECT *` in code that maps positionally | Breaks the next time a column is added |
| Case sensitivity and collation | Behaves differently between the dev database and production |

**Cross-language**

| Trap | What goes wrong |
|---|---|
| Local time, DST, leap days | Arithmetic on wall-clock times; `now()` on a server in a different zone |
| Wall clock for durations | NTP steps backwards; use a monotonic clock |
| Float for money | Use integer minor units or a decimal type |
| Encoding assumptions | Byte length vs character length; emoji, combining marks, non-ASCII names |
| Path handling | Separators, `..` traversal, symlinks, case-insensitive filesystems |
| Locale-dependent formatting or case-folding | Turkish dotless `i` breaks `toLowerCase` comparisons |

## High-risk domains

When ranking a large diff, these are where an hour of attention pays for itself. Each has
its own question to ask.

- **Authentication and authorisation** — does the new path check the same things the old
  one did? Is the check on the object being acted on, or only on the route? Can an ID from
  the request body select a resource belonging to someone else (IDOR)?
- **Money and quantities** — rounding direction, currency mixing, negative and zero,
  idempotency of charges and refunds, double-submit.
- **Migrations** — is it reversible? Does it lock a hot table? Does it work while both the
  old and new application versions are running? Is backfill separate from the schema
  change?
- **Concurrency and background jobs** — at-least-once delivery means the handler must be
  idempotent; retries with no backoff amplify an outage.
- **Public API and back-compat** — a field renamed, a default flipped, an error code
  changed, a response narrowed. Someone is depending on it.
- **Secrets and PII** — anything new reaching logs, error messages, analytics, or a URL.
- **Dependencies** — a new package: is it maintained, is the licence acceptable, does it
  pull in a transitive tree nobody looked at, is the version pinned?
- **Anything with `unsafe`, `eval`, raw SQL, a shell invocation, deserialisation, or a
  template engine** in it.

## Quality angles

These do not crash anything. They cost maintenance, and they are worth a non-blocking
comment when the alternative is concrete and nameable.

**Reuse** — does the new code re-implement something the repo already has? Grep the shared
and utility modules, and the files next to the change. Only flag it when you can name the
existing helper by path — "this probably exists somewhere" is not actionable.

**Simplification** — state that is derivable from other state, a flag that duplicates a
condition, copy-paste with a small variation that a parameter would cover, nesting that an
early return would flatten, dead code the change left behind, an abstraction introduced for
exactly one caller. Name the simpler form.

**Efficiency** — repeated I/O or recomputation inside a loop, independent operations run
sequentially that could run together, work added to startup or a hot path, an N+1 query.
Also: long-lived objects built from closures capture their entire enclosing scope and hold
it for the object's lifetime, which is a leak when that scope holds anything large — a
struct or class copying only the fields it needs does not. Judge everything here against
how hot the path actually is; a slow loop over three config entries is not a finding.

**Altitude** — is the change at the right depth? A special case layered onto shared
infrastructure, a flag threaded through four functions to reach one, a fix at the call site
for a problem in the callee, a second code path that duplicates the first with a tweak:
each is a sign the fix did not go deep enough. Say what generalising would look like. This
is a judgment call and usually belongs in the summary rather than as a blocking comment —
the author may know a constraint you do not.

## Conventions the repo writes down

A rule the project has written down is not a matter of your taste, which is exactly what
makes it worth citing. Find the files that govern the changed code:

- The user-level `~/.claude/CLAUDE.md`, if this run has one.
- The repo-root `CLAUDE.md` / `AGENTS.md`.
- Any `CLAUDE.md`, `CLAUDE.local.md`, or `AGENTS.md` in a directory that is an ancestor of a
  changed file — a directory's file governs that directory and below, and nothing else.
- `CONTRIBUTING.md`, the README, and the linter, formatter, and type-checker configs.

Read each one that applies, then check the diff against what it says.

**Only flag a violation you can quote both halves of**: the exact rule, and the exact
changed line that breaks it. Cite the file path in the comment. Anything softer than that —
a rule you are inferring from the document's spirit, a style preference the config does not
encode — is your taste again, and it does not survive contact with an author who disagrees.

Note the difference between a rule and a tool's job: if the formatter or linter enforces it,
CI will say so without your help, and the comment is noise.

## The sweep list

After deduplicating, take one more pass as a fresh reviewer holding the list, looking
**only** for what is not on it. These are the defects a first pass reliably misses:

- **Moved or extracted code that dropped something** — a guard, a null check, a regex
  anchor (`^…$` lost when a pattern became a shared constant), a `defer`, an early return.
  Diff the moved block against its original rather than reading it fresh.
- **A default that flipped** — a config value, a feature flag, a timeout, a retry count, a
  log level, a boolean parameter's default. One-character diffs with wide blast radius.
- **A constant changed in one of the two places it lives** — the code and the docs, the
  schema and the model, the enum and the switch over it.
- **An enum or union widened without every consumer updated** — a new variant that falls
  into a `default:` branch that was previously unreachable.
- **Second-tier language traps** — a default evaluated once at definition time, `hash()` or
  map-iteration nondeterminism relied on for ordering, a lock scope narrowed, a predicate or
  getter that now has a side effect, a `__repr__`/`toString` that can throw.
- **Setup/teardown asymmetry in tests** — a fixture created and never cleaned up, a global
  patched without restoration, a shared temp directory two tests both write to.
- **Error messages and logs** — a message that now names a variable that can be nil, a log
  line inside a loop that will produce thousands, a user-facing string that leaks an
  internal path or ID.
- **Documentation the change made untrue** — a docstring describing the old parameter, a
  README example that no longer runs, a comment above the line that contradicts it.

If nothing new surfaces, return nothing. A padded sweep is worse than an empty one.
