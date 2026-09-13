# ebook-library-tools-next — Project Recommendations

## 1. Purpose

This document defines the overall architectural, development, and future-feature recommendations for `ebook-library-tools-next`.

The goal is **not** to rewrite the old project for the sake of rewriting it.

The goal is:

> **Turn a collection of working shell scripts into a predictable, testable Unix-style toolkit with explicit boundaries.**

The refactoring should preserve working behavior while making the project easier to understand, test, maintain, extend, and operate safely.

---

# 2. Current Position

The project has reached an important checkpoint.

### Phase 3 — `lib/` Infrastructure

**Status: COMPLETE**

Current regression baseline:

```text
Test scripts:  16
Passed:        16
Failed:         0
```

The foundational infrastructure includes:

```text
lib/
├── common.sh
├── logging.sh
├── cli.sh
├── filesystem.sh
└── database.sh
```

The infrastructure tests cover:

- Bash syntax
- idempotent library sourcing
- `common_init`
- DEBUG handling
- project-root detection
- logging contracts
- CLI contracts
- filesystem helpers
- database command construction
- database execution through a mock client
- real-repository loading

This **16/16 passing baseline should be protected** throughout the remaining refactoring.

---

# 3. Core Architectural Direction

Do **not** restart the project or perform another broad redesign.

The current direction is sound.

The desired architecture is:

```text
┌─────────────────────────────────────────────┐
│                 bin/                        │
│          User-facing commands               │
├─────────────────────────────────────────────┤
│                 domain                      │
│ authors / books / library / etc.             │
├─────────────────────────────────────────────┤
│                 lib/                        │
│       Shared infrastructure                  │
├─────────────────────────────────────────────┤
│             external systems                │
│ filesystem / MariaDB / network / tools      │
└─────────────────────────────────────────────┘
```

The dependency direction should be:

```text
application → infrastructure
```

and never:

```text
infrastructure → application
```

The resulting project should feel **predictable and boring**.

That is a strength.

---

# 4. Strict Layer Boundaries

## `lib/`

`lib/` should contain generic reusable functionality:

- common initialization
- logging
- CLI processing
- filesystem operations
- database execution

It should not contain knowledge of:

- books
- authors
- library-specific business rules
- individual application workflows

## Domain/Application Layer

Application logic belongs in the appropriate domain area:

```text
authors/
books/
library/
```

or equivalent command-oriented organization.

Domain code may use `lib/`, but `lib/` must remain independent of the domain.

---

# 5. One Executable — One Responsibility

Apply the Unix philosophy:

> **One command, one job.**

Examples:

```text
authors-export
authors-prefix-build
authors-prefix-tree
books-estimate
books-finalize
books-merge
books-reconcile
library-populate
library-refresh
library-report
```

Each command should have:

1. clear input
2. clear output
3. predictable exit status
4. no hidden side effects
5. `--help`
6. `--version`
7. optional `--debug`
8. documented dependencies

Avoid creating giant scripts that perform unrelated operations.

---

# 6. Testing as a Contract

The test suite should be treated as an architectural contract.

Recommended development cycle:

```text
make change
    ↓
run focused tests
    ↓
run complete regression suite
    ↓
git diff --check
    ↓
commit
```

A future unified runner should make the entire suite easy to execute:

```bash
tests/run_all.sh
```

or an equivalent project-level command.

A desirable result is:

```text
== ebook-library-tools-next test suite ==

PASS authors export
PASS authors prefix build
PASS authors prefix tree
...
PASS infrastructure
PASS version synchronization

-------------------------------------------
Tests: 16
Passed: 16
Failed: 0

ALL TESTS PASSED
```

The number of tests should grow as coverage improves.

---

# 7. Unit, Integration, and E2E Tests

The project already contains different levels of testing.

Make the distinction explicit through either directories or naming conventions.

Possible structure:

```text
tests/
├── unit/
├── integration/
└── e2e/
```

Or retain the existing organization and use names such as:

```text
test_lib_*.sh
test_authors_*.sh
test_library_*.sh
test_e2e_*.sh
```

The important objective is to identify the scope of a failure quickly.

---

# 8. Database as a Hard Boundary

`lib/database.sh` should remain **opt-in**.

Database-independent commands should not automatically load database infrastructure.

Database-dependent commands may explicitly use:

```bash
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/database.sh"
```

Low-level database mechanics should remain inside `database.sh`, including functions such as:

```text
db_mysql_argv
db_run_sql
db_run_query
```

Application code should express database operations at a useful abstraction level rather than reconstructing the complete MariaDB/MySQL command line.

---

# 9. Dry-Run as a First-Class Capability

For operations that modify files, directories, or databases:

```text
--dry-run
```

should mean:

> **No persistent state is modified.**

This should be a project-wide contract.

For important operations, test dry-run behavior using before/after state comparisons:

```text
capture state fingerprint
        ↓
run --dry-run
        ↓
capture state fingerprint
        ↓
must be identical
```

This is especially important for large ebook libraries.

---

# 10. Deterministic Processing

Aim for:

```text
same input
   +
same database
   +
same configuration
   =
same output
```

Avoid unnecessary nondeterminism caused by:

- filesystem traversal order
- implicit locale
- current working directory
- timestamps in generated content
- random values in persistent output
- unordered SQL results
- uncontrolled environment differences

Determinism should be treated as a feature because it improves:

- testing
- reproducibility
- debugging
- incremental processing
- user confidence

---

# 11. Explicit Path Semantics

The project may be accessed through different WSL paths representing the same physical repository.

For example:

```text
/home/mike/GIT_ROOT/ebook-library-tools-next
```

and:

```text
/mnt/c/git_root/ebook-library-tools-next
```

The project should distinguish between:

### Logical Path

The path supplied by the caller.

### Canonical Physical Path

The resolved path used internally.

Recommended contract:

```text
PROJECT_ROOT
```

always represents the canonical physical project root.

Tests should compare canonical paths where appropriate.

---

# 12. Configuration

Configuration should remain separate from implementation.

A possible future structure is:

```text
config/
├── defaults.sh
├── development.sh
├── production.sh
└── local.example.sh
```

Configuration values such as:

```text
MYSQL_HOST
MYSQL_PORT
MYSQL_USER
MYSQL_DATABASE
```

should be treated as configuration concerns rather than being scattered throughout application scripts.

Secrets must never be committed.

---

# 13. Documentation Strategy

Documentation should exist at three levels.

## `README.md`

Concise project overview:

- what the project is
- why it exists
- quick start
- current status

## `docs/UserGuide.md`

End-user documentation:

- installation
- dependencies
- configuration
- command order
- workflows
- examples
- troubleshooting

## `docs/Architecture.md`

Maintainer documentation:

- directory structure
- layer boundaries
- dependency direction
- library responsibilities
- domain responsibilities
- data flow
- database interaction
- testing strategy
- naming conventions
- exit codes
- configuration rules

---

# 14. Bash vs. Other Languages

Keep Bash where it is strong:

```text
CLI handling
filesystem orchestration
calling external programs
simple ETL pipelines
Unix utilities
```

Consider Python or SQL when a component requires:

- complex parsing
- large in-memory data structures
- complicated algorithms
- heavy concurrency
- sophisticated data transformations

Recommended philosophy:

> **Bash orchestrates; specialized tools do the heavy work.**

Do not perform a wholesale Python rewrite merely for the sake of modernization.

---

# 15. Coding Standards

Formalize and enforce:

- `bash -n`
- ShellCheck
- Google Shell Style where practical
- `set -u`
- `pipefail`
- controlled `errexit`
- standard script headers
- standard function headers
- English comments
- consistent variable naming
- consistent exit codes
- readable modular functions
- no duplicated infrastructure

A future project quality command could be:

```bash
./tools/check.sh
```

covering:

```text
syntax
ShellCheck
header validation
documentation checks
test suite
```

---

# 16. Git Strategy

Use small, meaningful commits.

Examples:

```text
refactor: complete Phase 3 library infrastructure
refactor: standardize author processing pipeline
test: expand library refresh regression coverage
docs: document database architecture
fix: preserve canonical project root detection
```

Avoid vague commits such as:

```text
fix stuff
changes
update scripts
refactoring
more fixes
```

The Git history should tell the architectural story of the project.

---

# 17. Definition of Done

Every phase should have explicit entry and exit criteria.

Recommended workflow:

```text
Entry criteria
      ↓
Implementation
      ↓
Focused tests
      ↓
Full regression suite
      ↓
Documentation
      ↓
git diff --check
      ↓
Commit
      ↓
Exit criteria
```

Do not knowingly carry unresolved phase violations into the next phase.

---

# 18. Future Capabilities

Future features should be divided into three categories:

```text
NOW
    Build architectural hooks and contracts.

NEXT
    Implement capabilities with immediate operational value.

LATER
    Implement only when real usage demonstrates the need.
```

The guiding principle is:

> **Design for future capabilities without allowing future capabilities to derail the current refactoring.**

---

## 18.1 Configuration Profiles — HIGH PRIORITY

Support multiple operating environments without scattering configuration through scripts.

Possible future usage:

```bash
library-refresh --config development
library-refresh --config production
```

Benefits:

- cleaner deployment
- safer environment separation
- easier testing
- fewer hard-coded assumptions

Recommendation:

**Build the configuration architecture early, but keep it simple.**

---

## 18.2 Machine-Readable `--json` Output — HIGH PRIORITY

Human-readable output should remain the default.

Selected commands could additionally support:

```bash
library-refresh --json
```

Example:

```json
{
  "processed": 12453,
  "added": 842,
  "updated": 1107,
  "skipped": 94,
  "errors": 12
}
```

This enables integration with:

```text
jq
Python
automation
monitoring
CI
other Unix tools
```

Recommendation:

**Add JSON output where it provides real automation value.**

---

## 18.3 Preflight / Validation Mode — HIGH PRIORITY

Provide a safe validation operation such as:

```bash
library-refresh --check
```

or:

```bash
library-populate --validate
```

Potential checks:

```text
✓ database reachable
✓ expected schema exists
✓ expected tables exist
✓ required directories exist
✓ required external programs installed
✓ configuration valid
✓ input files available
✓ sufficient disk space
✓ no conflicting operation running
```

Desired result:

```text
PRECHECK PASSED
Safe to proceed.
```

This should prevent failures after an expensive operation has already started.

---

## 18.4 Locking / Concurrency Protection — HIGH PRIORITY

Protect operations that modify shared files or databases.

Conceptually:

```text
operation
    ↓
acquire lock
    ↓
perform operation
    ↓
release lock
```

This prevents accidental simultaneous execution of conflicting commands.

Locking should be implemented **before parallel processing**.

---

## 18.5 Incremental Processing — HIGH PRIORITY

Process only new or changed data instead of rebuilding everything.

Conceptual model:

```text
input
  ↓
fingerprint
  ↓
compare with previous state
  ↓
new/changed objects only
  ↓
process
```

This should become particularly valuable as the ebook library grows.

It can dramatically reduce runtime for normal updates.

---

## 18.6 Resume / Checkpoint Support — MEDIUM PRIORITY

Long-running operations should eventually support interruption and continuation.

Possible interface:

```bash
library-populate --resume
```

Conceptually:

```text
10,000 items
     ↓
processed 4,273
     ↓
failure / interruption
     ↓
restart
     ↓
continue from remaining work
```

Implement only after processing is deterministic and state tracking is reliable.

---

## 18.7 Transaction-Aware Database Operations — MEDIUM/HIGH PRIORITY

For operations affecting multiple related tables, define logical transaction boundaries.

Conceptually:

```text
START TRANSACTION
       ↓
multiple related changes
       ↓
COMMIT
```

On failure:

```text
ROLLBACK
```

The application/domain layer should define what constitutes one logical operation, while the database infrastructure handles the low-level mechanics.

---

## 18.8 Configuration Validation — MEDIUM PRIORITY

Provide a dedicated configuration validation capability.

Example:

```text
Configuration
────────────────────────────
Database host       PASS
Database port       PASS
Database name       PASS
Library directory   PASS
Temporary directory PASS
Required tools      PASS
Permissions         PASS

Configuration is valid.
```

This complements preflight validation.

---

## 18.9 Parallel Processing — LATER

Parallel processing may eventually be useful:

```bash
authors-prefix-build --jobs 8
```

or:

```bash
library-refresh --jobs 4
```

But it should come only after:

1. deterministic behavior is established
2. shared-state locking is implemented
3. database operations are safe
4. transaction boundaries are understood
5. concurrency-sensitive tests exist

Premature parallelism should be avoided.

---

## 18.10 Extension / Plugin Architecture — LATER

Do not build a plugin framework now.

Instead, maintain an architecture where new domain operations can be added without modifying infrastructure.

For example:

```text
authors/
    export
    prefix
    tree

books/
    estimate
    merge
    reconcile

library/
    populate
    refresh
    report
```

This provides practical extensibility without introducing framework overhead.

---

# 19. Features to Explicitly Defer

The following should **not** be part of the current refactoring:

### Web UI

Do not build one until a demonstrated need exists.

### REST API

Avoid adding a service layer before there is a concrete consumer.

### Full Python Rewrite

Do not rewrite working shell orchestration simply because Python is available.

### Containerization

Docker or similar tooling may be useful later, but should not complicate the core refactoring.

### General-Purpose Plugin Framework

Design for extensibility without implementing an extension framework prematurely.

---

# 20. Recommended Future Architecture

The long-term architecture should evolve toward:

```text
                         ┌───────────────┐
                         │     User      │
                         └───────┬───────┘
                                 │
                                 ▼
                         ┌───────────────┐
                         │     bin/      │
                         │ CLI commands  │
                         └───────┬───────┘
                                 │
                  ┌──────────────┼──────────────┐
                  ▼              ▼              ▼
             authors/        books/          library/
                  │              │              │
                  └──────────────┼──────────────┘
                                 ▼
                         ┌───────────────┐
                         │     lib/      │
                         ├───────────────┤
                         │ common        │
                         │ logging       │
                         │ cli           │
                         │ filesystem    │
                         │ database      │
                         └───────┬───────┘
                                 │
                 ┌───────────────┼───────────────┐
                 ▼               ▼               ▼
             filesystem       MariaDB        Unix tools
```

With future operational capabilities around the command layer:

```text
       configuration
             │
             ▼
CLI → preflight → lock → operation → transaction
                         │
                         ├── dry-run
                         ├── progress
                         ├── logging
                         ├── deterministic output
                         └── JSON output
```

This provides a strong foundation without prematurely introducing unnecessary framework complexity.

---

# 21. Recommended Refactoring Roadmap

Continue incrementally:

```text
                CURRENT
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 3              │
        │ lib/ infrastructure  │
        │        ✓ COMPLETE    │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 4              │
        │ command organization │
        │ / bin/ architecture  │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 5              │
        │ authors pipeline     │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 6              │
        │ books pipeline       │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 7              │
        │ library operations   │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 8              │
        │ E2E / integration    │
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │ Phase 9              │
        │ docs + quality gates │
        └──────────┬───────────┘
                   │
                   ▼
             1.0 RELEASE
```

The exact details of later phases may evolve as implementation reveals new dependencies.

The incremental strategy should remain.

---

# 22. Recommended Priority Matrix

| Capability | Priority | Action |
|---|---:|---|
| Strict layer boundaries | Critical | Enforce now |
| Regression suite | Critical | Protect now |
| Deterministic processing | Critical | Enforce throughout |
| Dry-run contract | High | Standardize |
| Consistent exit codes | High | Formalize |
| Configuration profiles | High | Design now |
| Preflight validation | High | Implement |
| Locking | High | Implement before parallelism |
| Incremental processing | High | Plan and implement after foundations |
| JSON output | High | Add where useful |
| Transaction-aware DB operations | Medium/High | Implement where needed |
| Resume/checkpoints | Medium | Add for long-running workflows |
| Configuration validation | Medium | Add with preflight |
| Parallel processing | Later | Only after safety foundations |
| Extension/plugin mechanism | Later | Keep architecture open |
| Containerization | Later | Only if justified |
| REST API | Not now | Defer |
| Web UI | Not now | Defer |
| Full Python rewrite | Not now | Do not pursue |

---

# 23. Working Philosophy

Throughout the remaining refactoring:

### Preserve working behavior

Refactor first. Change functionality deliberately and separately.

### Prefer explicit behavior

Hidden magic makes shell projects difficult to maintain.

### Prefer small functions

Each function should have one clear purpose.

### Prefer reusable infrastructure

Do not duplicate logging, CLI, filesystem, or database mechanics.

### Prefer deterministic output

Determinism makes testing and troubleshooting dramatically easier.

### Prefer safe failure

A command should fail clearly rather than silently corrupting state.

### Prefer testable interfaces

Functions should accept explicit arguments rather than depending unnecessarily on globals.

### Prefer documentation as part of implementation

When architecture or behavior changes, update the relevant documentation during the same phase.

### Design for the future, implement for today

Create clean interfaces and extension points without implementing speculative features prematurely.

---

# 24. Definition of Long-Term Success

The success of the project should **not** be measured by how much old code was rewritten.

The resulting project should be:

- predictable
- modular
- testable
- maintainable
- deterministic
- safe to operate
- understandable to another developer
- easy to extend

A developer should be able to answer these questions without reverse-engineering the repository:

```text
Where does this command start?
Where does it get its infrastructure?
What does it modify?
What database does it access?
What are its inputs?
What are its outputs?
What happens on failure?
How do I test it?
How do I run it safely?
```

That is the real objective of the refactoring.

---

# 25. Current Checkpoint

```text
Project:       ebook-library-tools-next
Phase:         3 — lib/ infrastructure
Status:        COMPLETE

Test scripts:  16
Passed:        16
Failed:         0

Infrastructure:
    common.sh       PASS
    logging.sh      PASS
    cli.sh          PASS
    filesystem.sh   PASS
    database.sh     PASS

Regression suite:  PASS
```

This checkpoint should be preserved as the baseline for the remaining phases.

---

# 26. Final Recommendation

Continue the refactoring **incrementally**.

Do not pursue another broad rewrite.

Protect the existing regression suite and use it as the safety net for every subsequent architectural change.

The project is moving from:

```text
"collection of scripts that work"
```

toward:

```text
"coherent Unix-style toolkit with explicit architecture"
```

The five future capabilities worth keeping most strongly in sight are:

1. **Preflight validation**
2. **Locking / concurrency protection**
3. **Deterministic and incremental processing**
4. **Machine-readable JSON output**
5. **Configuration profiles**

These provide substantial practical value while fitting naturally into the architecture already being built.

The guiding principle for the entire project should remain:

> **Build a small, reliable core first. Add complexity only when real requirements justify it.**
