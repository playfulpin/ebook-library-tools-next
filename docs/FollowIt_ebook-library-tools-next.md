# ebook-library-tools-next — Follow-It Refactoring & Development Guide

## 1. Purpose

The goal of this project is **not** simply to rewrite the old project.

The goal is:

> **Turn a collection of working shell scripts into a predictable, testable Unix-style toolkit with explicit boundaries.**

The refactoring should make the project easier to understand, test, maintain, extend, and use without sacrificing the functionality that already works.

---

## 2. Current Status

### Phase 3 — `lib/` Infrastructure

**Status: COMPLETE**

The current regression checkpoint is:

- Test scripts: **16**
- Passed: **16**
- Failed: **0**
- Infrastructure tests: **PASS**

The project has a working foundational infrastructure layer consisting of:

- `lib/common.sh`
- `lib/logging.sh`
- `lib/cli.sh`
- `lib/filesystem.sh`
- `lib/database.sh`

The infrastructure regression suite verifies:

- Bash syntax
- Idempotent library sourcing
- `common_init` behavior
- DEBUG handling
- Project-root detection
- Logging contracts
- CLI contracts
- Filesystem helpers
- Database command construction
- Database execution through a mock client
- Real-repository loading

A WSL path/canonicalization issue in the real-repository test was also identified and corrected by comparing canonical physical paths.

---

# 3. Overall Architectural Recommendation

Do **not** restart the project or perform another large redesign.

The current direction is good. The priority now should be to make the architecture **predictable and boring**.

A future developer should be able to look at a script and immediately understand:

> This is a command-line tool. It gets infrastructure from `lib/`, performs one specific job, and can be tested independently.

A recommended high-level structure is:

```text
ebook-library-tools-next/
│
├── bin/                 # User-facing executables
├── lib/                 # Shared infrastructure
├── tests/               # Regression and integration tests
├── data/                # Runtime/input data
├── docs/                # Architecture and user documentation
└── ...
```

---

# 4. Establish Strict Layer Boundaries

> **Status (2026-09-13): LANDED.**  Steps taken, each confirmed before
> work started:
> 1. Domain logic left `lib/` — `lib/books_functions.sh` inlined into
>    its only consumer `bin/books/books_merge.sh` (commit `96cd0b5`);
>    every `lib/*.sh` is domain-free.
> 2. Infrastructure no longer names application tools —
>    `lib/database.sh`'s `db_require_server` message reworded
>    (`f76d9ae`).
> 3. The dependency rule is a CI gate — `bin/check_layers.sh` 1.0.0
>    enforces "lib/ domain-free, bin/ → lib/ only" and fails the build
>    on violation (`868c42b`); documented exemption: the AWK parity
>    reference (C7).
> 4. As-built docs reconciled — ARCHITECTURE §4/§5, README layout,
>    this note.

This is the most important architectural recommendation.

Use a dependency direction like:

```text
┌─────────────────────────────────────────────┐
│                 bin/                        │
│          User-facing commands               │
├─────────────────────────────────────────────┤
│                 lib/                        │
│       Reusable infrastructure               │
├─────────────────────────────────────────────┤
│              domain logic                   │
│ authors / books / library / etc.             │
├─────────────────────────────────────────────┤
│            external systems                 │
│ filesystem / MariaDB / network / tools      │
└─────────────────────────────────────────────┘
```

The practical dependency rule should be:

```text
application → infrastructure
```

and never:

```text
infrastructure → application
```

## `lib/`

`lib/` should contain generic reusable functionality such as:

- logging
- CLI processing
- filesystem operations
- database execution
- common initialization

It should **not** know what a book or author is.

## Domain Scripts

Scripts dealing with authors, books, and library operations should contain application/domain logic.

They may use `lib/`, but `lib/` should remain independent of them.

This separation is what makes the infrastructure reusable and testable.

---

# 5. One Executable, One Responsibility

Apply the Unix philosophy:

> **One command, one job.**

Examples include:

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

Each executable should have:

1. Clear input
2. Clear output
3. Predictable exit status
4. No hidden side effects
5. `--help`
6. `--version`
7. Optional `--debug`
8. Documented dependencies

Avoid turning individual commands into large "do everything" scripts.

---

# 6. Treat the Test Suite as a Contract

The current baseline of **16/16 passing test scripts** should become a protected regression checkpoint.

The preferred development cycle is:

```text
make change
    ↓
run focused tests
    ↓
run complete test suite
    ↓
git diff --check
    ↓
commit
```

Future refactoring should not proceed by knowingly breaking the regression baseline.

## Recommended Test Runner

Introduce a dedicated:

```text
tests/run_all.sh
```

or equivalent project-level test command.

It should determine its own repository location rather than depending on the caller's current working directory.

A desirable output would look like:

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

The exact number will grow as coverage increases.

---

# 7. Distinguish Unit, Integration, and E2E Tests

The project already has tests representing different levels.

Make the distinction explicit, either through directories or naming conventions.

For example:

```text
tests/
├── unit/
├── integration/
└── e2e/
```

Alternatively, preserve the existing organization and use names such as:

```text
test_lib_*.sh
test_authors_*.sh
test_library_*.sh
test_e2e_*.sh
```

The important point is to know what kind of failure occurred.

If an infrastructure test fails, debugging should begin in the infrastructure layer rather than immediately investigating the complete E2E pipeline.

---

# 8. Treat Database Access as a Hard Boundary

The decision that:

```text
lib/database.sh
```

is **opt-in rather than automatically sourced** is a good architectural choice.

Keep it that way.

A database-dependent command can explicitly load:

```bash
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/database.sh"
```

while filesystem-only commands need not load database functionality.

Keep low-level MariaDB/MySQL mechanics inside `database.sh`, including functions such as:

```text
db_mysql_argv
db_run_sql
db_run_query
```

Application scripts should think in terms of operations such as:

```text
run this SQL
```

rather than constructing the complete database-client command line themselves.

---

# 9. Make `--dry-run` a First-Class Feature

For commands that modify files, directories, or databases:

```text
--dry-run
```

should mean:

> **No persistent state is modified.**

It should not mean "most things are not modified."

For important operations, test this explicitly.

A useful pattern is:

```text
capture state fingerprint
        ↓
run --dry-run
        ↓
capture state fingerprint
        ↓
fingerprints must be identical
```

This is particularly valuable when processing large ebook libraries.

---

# 10. Make Data Transformations Deterministic

Where possible, aim for:

```text
same input
   +
same database
   +
same configuration
   =
same output
```

Avoid unnecessary sources of nondeterminism:

- filesystem traversal order
- implicit locale
- current working directory
- timestamps in generated content
- random temporary values in persistent output
- unordered SQL results
- environment-dependent behavior

The existing filesystem fingerprint tests demonstrate the right philosophy: output should be stable and testable.

Extend that principle throughout the project.

---

# 11. Establish Explicit Path Semantics

The recent WSL path issue is a useful example.

The same repository can be accessed through different paths, such as:

```text
/home/mike/GIT_ROOT/ebook-library-tools-next
```

and:

```text
/mnt/c/git_root/ebook-library-tools-next
```

These can represent the same physical repository.

The project should explicitly distinguish between:

### Logical Path

The path supplied by the user or caller.

### Canonical/Physical Path

The resolved path used internally by the infrastructure.

Recommended convention:

```text
PROJECT_ROOT
```

always represents the **canonical physical project root**.

Tests should compare canonical paths when validating this contract.

---

# 12. Separate Configuration from Code

Keep runtime configuration separate from implementation.

A future structure might include:

```text
config/
├── defaults.sh
├── local.example.sh
└── ...
```

Environment variables such as:

```text
MYSQL_HOST
MYSQL_PORT
MYSQL_USER
MYSQL_DATABASE
```

should be treated as configuration concerns rather than being scattered throughout application scripts.

Secrets must never be committed to the repository.

---

# 13. Documentation Strategy

Documentation should exist at three levels.

## `README.md`

Keep the top-level README concise.

It should answer:

- What is this project?
- Why does it exist?
- How do I get started?
- What is the current project status?

## `docs/UserGuide.md`

This is for people using the tools.

It should cover:

- Installation
- Configuration
- Required dependencies
- Correct command order
- Typical workflows
- Examples
- Troubleshooting

## `docs/Architecture.md`

This is for maintainers.

It should describe:

- Directory structure
- Layer boundaries
- Dependency direction
- Library responsibilities
- Domain/application responsibilities
- Data flow
- Database interaction
- Testing strategy
- Naming conventions
- Exit-code conventions
- Configuration rules

The architecture document will become increasingly valuable as the refactoring progresses.

---

# 14. Do Not Over-Engineer Bash

Keep Bash where it is genuinely strong:

```text
CLI handling
filesystem orchestration
calling external programs
simple ETL pipelines
Unix utilities
```

When a component starts requiring:

- complex parsing
- large in-memory data structures
- complicated algorithms
- heavy concurrency
- sophisticated database transformations

consider using Python or SQL instead of building increasingly complex machinery in Bash.

A good long-term model is:

> **Bash orchestrates; specialized tools do the heavy work.**

---

# 15. Formalize the Shell Coding Standards

The project already has a strong style direction. Make it explicit and enforce it.

Recommended standards include:

- `bash -n`
- ShellCheck
- Google Shell Style where practical
- `set -u`
- `pipefail`
- controlled `errexit` behavior
- English comments
- standard script headers
- standard function headers
- consistent variable naming
- consistent exit codes
- no duplicated infrastructure
- readable modular functions

Automate these checks where practical.

A future quality command could be:

```bash
./tools/check.sh
```

which runs:

```text
syntax checks
ShellCheck
header validation
documentation checks
test suite
```

---

# 16. Git Strategy

Use small, meaningful commits.

Good examples:

```text
refactor: complete Phase 3 library infrastructure
refactor: standardize author processing pipeline
test: expand library refresh regression coverage
docs: document database architecture
fix: preserve canonical project root detection
```

Avoid vague commit messages such as:

```text
fix stuff
changes
update scripts
refactoring
more fixes
```

The Git history should explain the architectural evolution of the project.

---

# 17. Definition of Done

Every refactoring phase should have explicit entry and exit criteria.

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

Do not move to the next phase while the current phase knowingly violates its exit criteria.

This prevents the refactoring from becoming another partially refactored codebase.

---

# 18. Recommended Refactoring Roadmap

The project should continue incrementally.

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

The exact phase contents can evolve as implementation reveals new dependencies, but the incremental structure should remain.

---

# 19. Recommended Working Philosophy

The project should follow these principles throughout the remaining refactoring:

### Preserve working behavior

Refactor first; change functionality deliberately and separately.

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

### Prefer documentation as part of the implementation

When behavior or architecture changes, update the relevant documentation in the same phase.

---

# 20. The Most Important Success Criterion

The ultimate measure of success is **not** how much old code was rewritten.

It is whether the resulting project is:

- predictable
- modular
- testable
- maintainable
- deterministic
- safe to operate
- understandable to another developer
- easy to extend

The target is a toolkit where a developer can confidently answer:

```text
Where does this command start?
Where does it get its infrastructure?
What does it modify?
What database does it access?
What are its inputs and outputs?
What happens on failure?
How do I test it?
How do I run it safely?
```

without reverse-engineering the entire repository.

---

# 21. Current Checkpoint

As of the completion of Phase 3:

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

This is the baseline to protect as the project moves into the next phases.

---

## Final Recommendation

Continue the refactoring **incrementally**, preserving the current test baseline.

Do not pursue another broad rewrite.

The project is now moving from:

```text
"collection of scripts that work"
```

toward:

```text
"coherent Unix-style toolkit with explicit architecture"
```

That should remain the guiding objective for every remaining phase.
