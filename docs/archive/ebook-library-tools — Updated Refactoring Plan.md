# ebook-library-tools — Updated Refactoring Plan

**Project:** `ebook-library-tools`  
**Refactoring repository:** `ebook-library-tools-next`  
**Plan status:** Updated September 12, 2026

---

## 1. Purpose

This document defines the complete refactoring roadmap for `ebook-library-tools-next`.

The goal is **not** to rewrite the project blindly or create a new application from scratch. The preferred strategy is to preserve useful functionality and project history while systematically improving:

- project structure;
- naming and consistency;
- separation of concerns;
- script interfaces;
- reusable libraries;
- configuration handling;
- data flow;
- error handling;
- testing;
- documentation;
- maintainability;
- CI/linting;
- user-facing workflows.

The resulting project should have a clear, predictable Unix/Linux-style command-line architecture and should be suitable for continued development.

---

# 2. Refactoring Principles

## 2.1 Preserve working functionality

Do not change behavior merely for stylistic reasons.

Every functional change should have a documented reason and, where practical, a test demonstrating the intended behavior.

## 2.2 Refactor incrementally

Avoid a single massive rewrite.

Each phase should leave the repository in a usable state and should produce a clear commit boundary.

## 2.3 Preserve history

Where possible, use Git moves/renames rather than deleting and recreating equivalent files.

The original repository history is valuable documentation.

## 2.4 Separate concerns

Scripts should not simultaneously contain:

- CLI parsing;
- configuration;
- business logic;
- filesystem manipulation;
- database logic;
- formatting;
- logging;
- test code.

These responsibilities should be separated into appropriate modules.

## 2.5 Prefer reusable functions over duplicated shell code

Common operations should exist in one reusable implementation rather than being copied between scripts.

## 2.6 Keep user-facing commands simple

The user should be able to understand:

```text
command [options] [arguments]
```

without reading the implementation.

## 2.7 Fail safely

Operations involving:

- deletion;
- replacement;
- database modification;
- archive manipulation;
- bulk file operations

must be conservative and predictable.

Dry-run support should be retained or introduced where it provides meaningful protection.

---

# 3. Target Project Identity

The long-term project identity should be:

```text
ebook-library-tools
```

The `-next` repository is the refactoring/development copy.

The intention is eventually to merge the successful refactoring back into the primary project rather than permanently maintaining two unrelated implementations.

---

# 4. Phase 1 — Repository Inventory and Dependency Map

**Status: First phase**

Before changing implementation code, create a complete inventory of the current repository.

## 4.1 Repository tree

Document the complete current tree, including:

```text
bin/
lib/
config/
data/
tests/
docs/
scripts/
.github/
```

and all other existing directories/files.

For every relevant file determine:

- purpose;
- executable/library/document/configuration status;
- caller(s);
- dependencies;
- inputs;
- outputs;
- side effects;
- configuration dependencies;
- external commands;
- environment variables;
- tests;
- documentation references.

## 4.2 Dependency map

Build a dependency map covering:

### Shell dependencies

Examples:

```text
bash
awk
sed
grep
find
sort
xargs
jq
fzf
wget
curl
unzip
zip
tar
mysql/mariadb
```

Only commands actually used by the repository should be recorded.

### Script-to-script dependencies

For each script identify:

```text
script
 ├── sources
 ├── calls
 ├── reads
 ├── writes
 └── external dependencies
```

### Configuration dependencies

Identify:

- configuration files;
- environment variables;
- defaults;
- command-line overrides;
- hard-coded paths;
- credentials/secrets handling;
- implicit assumptions about current working directory.

### Data dependencies

Document:

```text
INPUT
  ↓
PROCESSING
  ↓
INTERMEDIATE DATA
  ↓
OUTPUT
```

This is especially important for scripts manipulating ebook databases, archives, INPX files, SQL dumps, metadata, and library files.

## 4.3 File disposition

Every significant source file should receive one proposed disposition:

```text
KEEP
RENAME
MOVE
MERGE
SPLIT
REWRITE
DEPRECATE
DELETE
```

No file should disappear simply because it "looks old."

The reason for deletion must be documented.

## 4.4 Duplicate/obsolete functionality

Identify:

- duplicate scripts;
- duplicate functions;
- obsolete scripts;
- superseded implementations;
- abandoned experiments;
- generated files;
- temporary files;
- obsolete documentation;
- obsolete configuration;
- dead code.

---

# 5. Phase 1 Deliverables

The first phase should produce:

```text
docs/
├── REPOSITORY_INVENTORY.md
├── DEPENDENCY_MAP.md
├── DATA_FLOW.md
└── REFACTORING_DECISIONS.md
```

The inventory should include a table similar to:

| Current File | Purpose | Dependencies | Used By | Proposed Action |
|---|---|---|---|---|
| ... | ... | ... | ... | KEEP / MOVE / RENAME / ... |

The dependency map should include both textual documentation and a concise visual/tree representation where useful.

---

# 6. Phase 2 — Define the Target Architecture

After the inventory is complete, freeze the target architecture before large-scale code movement.

A proposed high-level layout is:

```text
ebook-library-tools/
├── bin/
│   ├── <user-facing-command>
│   └── ...
│
├── lib/
│   ├── common.sh
│   ├── logging.sh
│   ├── filesystem.sh
│   ├── archive.sh
│   ├── database.sh
│   ├── progress.sh
│   └── ...
│
├── config/
│   └── config.sh
│
├── data/
│   └── .gitkeep
│
├── tests/
│   ├── unit/
│   ├── integration/
│   └── fixtures/
│
├── docs/
│   ├── UserGuide.md
│   ├── DEVELOPMENT.md
│   ├── ARCHITECTURE.md
│   └── ...
│
├── .github/
│   └── workflows/
│
├── README.md
└── LICENSE
```

The exact directory contents must be determined by Phase 1 rather than imposed blindly.

---

# 7. Phase 3 — Establish Common Shell Infrastructure

Create the common foundation before converting individual commands.

## 7.1 Common initialization

Standardize:

```bash
#!/usr/bin/env bash

set -Eeuo pipefail
```

where compatible with the project's supported environment.

Any known compatibility exception must be documented rather than silently ignored.

## 7.2 Script location handling

Every executable should determine its own location reliably.

Do not depend on the current working directory.

For example:

```text
SCRIPT_DIR
PROJECT_ROOT_DIR
```

should be calculated consistently.

## 7.3 Common logging

Centralize:

- log levels;
- timestamps;
- errors;
- warnings;
- debug output;
- optional JSON logging if required;
- log-file handling.

## 7.4 Common CLI conventions

Standardize:

```text
-h / --help
-v / --version
--debug
--dry-run
```

where applicable.

Option names and semantics should be consistent across commands.

## 7.5 Common progress reporting

Use one reusable progress implementation.

The established interface should remain:

```bash
progress_start TOTAL [MESSAGE]
progress_tick
progress_finish
```

Internal state should remain encapsulated.

Avoid passing progress state through unrelated global variables.

---

# 8. Phase 4 — Refactor Individual Commands

Refactor scripts one at a time.

Recommended order:

1. foundational/common scripts;
2. low-risk filesystem/archive utilities;
3. data transformation tools;
4. INPX-related tools;
5. database utilities;
6. high-risk import/update tools.

For every command:

```text
CLI
 ↓
parse_cli_args()
 ↓
load configuration
 ↓
initialize environment/logging
 ↓
validate input
 ↓
business logic
 ↓
output/reporting
 ↓
cleanup
```

Avoid putting the entire implementation in `main()`.

---

# 9. Phase 5 — Function Header and Coding Standards

Standardize shell source files using the project's established documentation style.

## 9.1 File headers

Use a consistent header containing:

```text
Title
Script Name
Description
Project
Author
Date
Version
Options
Notes / Requirements
```

## 9.2 Function headers

Each non-trivial function should document:

- function name;
- description;
- logical steps;
- arguments;
- return value/status;
- relevant side effects.

Use the established separator format:

```bash
# -----------------------------------------------------------------------------
# function_name
# -----------------------------------------------------------------------------
```

Avoid unnecessary spaces inside comment blocks where the established project style requires compact formatting.

## 9.3 Shell quality

Use:

- ShellCheck;
- consistent quoting;
- meaningful variable names;
- readonly constants where appropriate;
- one variable definition per line;
- predictable return codes;
- no accidental word splitting;
- no unnecessary subshells;
- no duplicated logic.

---

# 10. Phase 6 — Configuration Cleanup

Configuration should be centralized.

Separate:

```text
configuration
```

from:

```text
runtime state
```

and from:

```text
temporary data
```

Configuration should contain:

- paths;
- URLs;
- defaults;
- external command configuration;
- retry/timeout values;
- user-adjustable settings.

Runtime variables should not accidentally overwrite persistent configuration.

Dry-run execution must not modify normal persistent state.

---

# 11. Phase 7 — Filesystem and Data Safety

All destructive operations must be reviewed.

Examples:

```text
rm
mv
cp
mkdir
archive replacement
database import
database cleanup
```

Before destructive operations:

1. validate paths;
2. validate input;
3. reject empty/unexpected paths;
4. verify required files;
5. honor `--dry-run`;
6. log the operation;
7. return a useful error code.

For bulk operations, provide a clear summary:

```text
Files examined
Files changed
Files skipped
Files failed
Total size
Elapsed time
```

---

# 12. Phase 8 — Database Utilities

Database-related scripts deserve separate treatment because mistakes can damage large datasets.

Standardize:

- database connection parameters;
- server/client encoding;
- schema selection;
- transaction behavior where applicable;
- import/export handling;
- backup behavior;
- error handling;
- dry-run behavior;
- validation.

Database scripts should never silently invent keys or relationships.

Where data is imported from an existing authoritative database, the existing source data should remain the source of truth.

---

# 13. Phase 9 — Testing Strategy

Move toward a layered test structure.

```text
tests/
├── unit/
├── integration/
└── fixtures/
```

## Unit tests

Test individual functions such as:

- argument parsing;
- path calculation;
- filename handling;
- prefix generation;
- archive selection;
- validation;
- progress calculations.

## Integration tests

Test complete command workflows.

Examples:

```text
input
 ↓
command
 ↓
expected filesystem/database result
```

## Safety tests

Explicitly test:

- `--dry-run`;
- missing input;
- invalid paths;
- empty directories;
- duplicate input;
- interrupted execution;
- failed external command;
- partially completed operation.

---

# 14. Phase 10 — Documentation

Documentation should describe the project from three perspectives.

## End users

`docs/UserGuide.md`

Include:

- prerequisites;
- installation;
- configuration;
- command order;
- command syntax;
- examples;
- expected output;
- common errors;
- safe/dry-run usage.

## Developers

`docs/DEVELOPMENT.md`

Include:

- project structure;
- coding standards;
- function headers;
- testing;
- ShellCheck;
- release process;
- contribution workflow.

## Architecture

`docs/ARCHITECTURE.md`

Include:

- component relationships;
- data flow;
- configuration model;
- dependency model;
- major design decisions.

---

# 15. Phase 11 — CI and Quality Gates

Add automated checks where practical.

Minimum recommended CI checks:

```text
ShellCheck
syntax validation
unit tests
documentation sanity checks
```

Potential future checks:

```text
function-header linter
duplicate-code detection
repository structure validation
integration tests
```

CI should fail clearly when a quality requirement is violated.

---

# 16. Phase 12 — Command Naming and Public Interface

Review all user-facing names.

A command name should describe what it does rather than how it was originally implemented.

Avoid names containing:

```text
test
new
old
v2
tmp
backup
final
final2
```

unless those words have a genuine semantic purpose.

When renaming a public command:

1. document the old name;
2. provide migration information;
3. preserve compatibility temporarily where practical;
4. remove the compatibility alias only after the new interface is established.

---

# 17. Phase 13 — Remove Legacy Material

Only after the replacement implementation is verified should obsolete material be removed.

Candidate categories:

```text
obsolete scripts
unused functions
duplicate implementations
temporary debugging code
generated artifacts
unused configuration
obsolete documentation
```

Do not delete anything during the initial inventory unless it is unquestionably generated or temporary.

---

# 18. Git Commit Strategy

Use small, meaningful commits.

Suggested sequence:

```text
01 inventory repository
02 document dependency map
03 define target architecture
04 add common shell infrastructure
05 standardize configuration
06 standardize logging
07 standardize progress handling
08 refactor command A
09 refactor command B
...
XX add tests
XX update documentation
XX remove obsolete code
XX final cleanup
```

Avoid commits such as:

```text
massive refactor
fix stuff
cleanup
misc changes
```

Each commit should have one understandable purpose.

---

# 19. Branch Strategy

Recommended branches:

```text
main
  │
  └── refactor/phase-1-inventory
       │
       ├── refactor/common-infrastructure
       ├── refactor/command-...
       └── refactor/testing
```

The exact branching model can be simplified if the repository is maintained by a single developer, but the logical phase boundaries should remain.

---

# 20. Refactoring Risk Classification

Every major component should receive a risk level.

### LOW

Examples:

- comments;
- documentation;
- formatting;
- obvious unused code.

### MEDIUM

Examples:

- function extraction;
- file moves;
- configuration restructuring;
- CLI cleanup.

### HIGH

Examples:

- database import/export;
- mass file operations;
- archive replacement;
- metadata transformations;
- changes to authoritative data.

High-risk changes require tests and explicit verification before proceeding.

---

# 21. Definition of Done

The refactoring is complete when:

- [ ] Repository inventory is complete.
- [ ] Dependency map is documented.
- [ ] Data flow is documented.
- [ ] Every significant file has a disposition.
- [ ] Target architecture is documented.
- [ ] Common infrastructure is centralized.
- [ ] CLI conventions are consistent.
- [ ] Configuration is centralized.
- [ ] Runtime state is separated from configuration.
- [ ] Destructive operations are validated.
- [ ] Dry-run behavior is safe.
- [ ] ShellCheck passes or documented exceptions exist.
- [ ] Function headers follow project standards.
- [ ] Unit tests cover important reusable functions.
- [ ] Integration tests cover critical workflows.
- [ ] Database operations are verified.
- [ ] User documentation is complete.
- [ ] Developer documentation is complete.
- [ ] CI performs automated quality checks.
- [ ] Obsolete code has been removed only after verification.
- [ ] Final repository tree is clean and understandable.

---

# 22. Recommended Execution Order

The overall sequence is:

```text
PHASE 1
Repository inventory
        ↓
Dependency map
        ↓
Data-flow analysis
        ↓
File disposition
        ↓
PHASE 2
Target architecture
        ↓
PHASE 3
Common infrastructure
        ↓
PHASE 4
Individual command refactoring
        ↓
PHASE 5
Coding/function-header standards
        ↓
PHASE 6
Configuration cleanup
        ↓
PHASE 7
Filesystem/data safety
        ↓
PHASE 8
Database utilities
        ↓
PHASE 9
Testing
        ↓
PHASE 10
Documentation
        ↓
PHASE 11
CI / quality gates
        ↓
PHASE 12
Public interface cleanup
        ↓
PHASE 13
Legacy removal
        ↓
FINAL REVIEW
```

---

# 23. Immediate Next Step

**Do not begin mass refactoring yet.**

The next concrete action is:

> **Complete Phase 1: Repository Inventory and Dependency Map.**

The output should be detailed enough that we can decide, file by file, what should be:

```text
KEEP
RENAME
MOVE
MERGE
SPLIT
REWRITE
DEPRECATE
DELETE
```

Only after that inventory is reviewed should Phase 2 architecture be finalized.

---

# 24. Strategic Goal

The final result should feel like **one coherent Unix/Linux toolset**, rather than a collection of historically accumulated scripts.

The desired architecture is:

```text
                ┌──────────────────┐
                │  User commands   │
                │      bin/        │
                └────────┬─────────┘
                         │
                         ▼
                ┌──────────────────┐
                │   CLI / config   │
                └────────┬─────────┘
                         │
                         ▼
                ┌──────────────────┐
                │ Reusable library │
                │      lib/        │
                └────────┬─────────┘
                         │
             ┌───────────┼───────────┐
             ▼           ▼           ▼
         Filesystem   Archives    Database
             │           │           │
             └───────────┼───────────┘
                         ▼
                  Library data
```

The most important objective is **predictability**:

> A developer should be able to open any command, understand where configuration comes from, identify the reusable functions it uses, determine what data it changes, and find the tests and documentation for that behavior.