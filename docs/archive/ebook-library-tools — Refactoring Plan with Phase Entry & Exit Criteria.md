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

# 3. Phase Governance

Every phase uses four gates:

```text
ENTRY CRITERIA
      ↓
   PHASE WORK
      ↓
MEASURABLE COMPLETION
      ↓
 EXIT CRITERIA
```

A phase may begin only when all mandatory entry criteria are satisfied.

A phase may be marked complete only when all mandatory measurable completion criteria and exit criteria are satisfied.

A phase may be **BLOCKED** rather than marked complete when an unresolved dependency prevents completion.

## Phase status values

Use only:

```text
NOT STARTED
READY
IN PROGRESS
BLOCKED
PASS
```

Do not use "mostly complete" or "essentially done" as a completion state.

---

# 4. Phase 1 — Repository Inventory & Dependency Map

**Objective:** Establish an accurate baseline before changing implementation code.

## Entry Criteria

- [ ] `ebook-library-tools-next` is available as the refactoring working repository.
- [ ] Current working tree status has been recorded.
- [ ] Current branch/commit has been recorded.
- [ ] Existing documentation has been located.
- [ ] Existing tests have been identified.
- [ ] No mass refactoring has started.

## Work

Inventory:

- source files;
- executable scripts;
- libraries;
- configuration;
- tests;
- documentation;
- generated files;
- external dependencies;
- script-to-script dependencies;
- data flow;
- hard-coded assumptions.

Every significant file receives:

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

## Measurable Completion Criteria

- [ ] 100% of tracked source files inventoried.
- [ ] 100% of executable scripts identified.
- [ ] 100% of significant configuration identified.
- [ ] 100% of public commands identified.
- [ ] 100% of significant external dependencies identified.
- [ ] 100% of significant input/output paths identified.
- [ ] 100% of significant files have a proposed disposition.
- [ ] Duplicate/obsolete functionality has been identified.
- [ ] `REPOSITORY_INVENTORY.md` exists.
- [ ] `DEPENDENCY_MAP.md` exists.
- [ ] `DATA_FLOW.md` exists.
- [ ] `REFACTORING_DECISIONS.md` exists.

## Exit Criteria

- [ ] Inventory coverage is **100%**.
- [ ] No significant file has an unknown purpose.
- [ ] No significant executable has an unknown caller/dependency status.
- [ ] No known configuration source is undocumented.
- [ ] No known critical data flow is undocumented.
- [ ] All unresolved questions are recorded in `REFACTORING_DECISIONS.md`.
- [ ] Phase 2 has enough information to define the target architecture without guessing.

**Exit status:** `PASS`

---

# 5. Phase 2 — Define Target Architecture

**Objective:** Establish the destination before moving substantial code.

## Entry Criteria

- [ ] Phase 1 = `PASS`.
- [ ] Repository inventory is available.
- [ ] Dependency map is available.
- [ ] Data-flow analysis is available.
- [ ] File dispositions have been reviewed.

## Work

Define:

- target directory structure;
- executable boundaries;
- reusable library boundaries;
- configuration ownership;
- data ownership;
- dependency direction;
- testing structure;
- documentation structure.

Proposed structure:

```text
ebook-library-tools/
├── bin/
├── lib/
├── config/
├── data/
├── tests/
├── docs/
└── .github/
```

The exact structure must be based on Phase 1 findings.

## Measurable Completion Criteria

- [ ] 100% of significant current directories have a target disposition.
- [ ] 100% of public commands have a target location.
- [ ] 100% of reusable components have an intended library location.
- [ ] Configuration ownership is defined.
- [ ] Runtime-state ownership is defined.
- [ ] Data-flow boundaries are defined.
- [ ] Dependency direction is documented.
- [ ] `ARCHITECTURE.md` exists.

## Exit Criteria

- [ ] Every significant component can answer:
  - who calls it;
  - what it owns;
  - what it depends on;
  - what it modifies;
  - where its tests live.
- [ ] No intentional circular dependency exists.
- [ ] Target structure is approved for implementation.
- [ ] No major architectural decision remains implicit.

**Exit status:** `PASS`

---

# 6. Phase 3 — Establish Common Shell Infrastructure

**Objective:** Create the shared foundation before refactoring individual commands.

## Entry Criteria

- [ ] Phase 2 = `PASS`.
- [ ] Target `bin/`, `lib/`, and `config/` structure is defined.
- [ ] Existing common functionality has been identified.
- [ ] Shell version/environment requirements are known.

## Work

Centralize:

- initialization;
- project-root detection;
- logging;
- error handling;
- progress reporting;
- common CLI conventions.

Standard progress API:

```bash
progress_start TOTAL [MESSAGE]
progress_tick
progress_finish
```

## Measurable Completion Criteria

- [ ] Common initialization exists.
- [ ] Project-root detection exists.
- [ ] Logging implementation exists.
- [ ] Progress implementation exists.
- [ ] Common CLI conventions are documented.
- [ ] Common error conventions are documented.
- [ ] 100% of converted scripts use the common infrastructure.
- [ ] Shell syntax checks pass.
- [ ] ShellCheck passes or every exception is documented.

## Exit Criteria

- [ ] No new duplicate implementation of shared infrastructure exists.
- [ ] All foundational infrastructure has at least basic tests.
- [ ] A clean checkout can load the common library successfully.
- [ ] Converted scripts execute successfully using the shared infrastructure.
- [ ] No undocumented ShellCheck violation remains.

**Exit status:** `PASS`

---

# 7. Phase 4 — Refactor Individual Commands

**Objective:** Convert commands to the target architecture one at a time.

## Entry Criteria

- [ ] Phase 3 = `PASS`.
- [ ] Target architecture exists.
- [ ] Common infrastructure is stable.
- [ ] Command has an inventory/disposition from Phase 1.
- [ ] Existing behavior is understood.
- [ ] Appropriate test strategy exists.

## Work

Refactor each command toward:

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

## Per-command Measurable Completion Criteria

- [ ] CLI parsing is isolated.
- [ ] Configuration loading is separated.
- [ ] Input validation precedes destructive work.
- [ ] Business logic is appropriately reusable.
- [ ] Common logging is used.
- [ ] Common progress handling is used where required.
- [ ] Error handling is predictable.
- [ ] Cleanup is reliable.
- [ ] No unnecessary global state remains.
- [ ] `--help` works.
- [ ] Normal execution works.
- [ ] Invalid input fails safely.
- [ ] Dry-run works where applicable.
- [ ] Critical behavior has tests.
- [ ] ShellCheck passes.

## Overall Exit Criteria

- [ ] 100% of planned commands have been refactored.
- [ ] 100% of command-specific tests pass.
- [ ] 100% of critical workflows still function.
- [ ] No known behavior regression remains unexplained.
- [ ] No command depends on deprecated internal interfaces unless explicitly documented.

**Exit status:** `PASS`

---

# 8. Phase 5 — Function Headers & Coding Standards

**Objective:** Make the codebase internally consistent and maintainable.

## Entry Criteria

- [ ] Phase 4 = `PASS`, or the specific source set being standardized is stable.
- [ ] Coding conventions are defined.
- [ ] Existing project header style has been reviewed.

## Measurable Completion Criteria

- [ ] 100% of production shell files have standardized headers.
- [ ] 100% of non-trivial production functions have function headers.
- [ ] Arguments are documented.
- [ ] Return behavior is documented.
- [ ] Side effects are documented where relevant.
- [ ] Naming conventions are consistent.
- [ ] Quoting has been reviewed.
- [ ] ShellCheck passes or exceptions are documented.

## Exit Criteria

```text
Production functions meeting header standard / total non-trivial functions = 100%
```

and:

```text
Undocumented coding-standard exceptions = 0
```

**Exit status:** `PASS`

---

# 9. Phase 6 — Configuration Cleanup

**Objective:** Establish a predictable configuration model.

## Entry Criteria

- [ ] Phase 2 = `PASS`.
- [ ] Configuration sources are known from Phase 1.
- [ ] Runtime state has been identified.
- [ ] Temporary-data requirements are understood.

## Measurable Completion Criteria

- [ ] All persistent configuration sources are identified.
- [ ] Configuration ownership is centralized.
- [ ] Defaults are explicit.
- [ ] Environment overrides are documented.
- [ ] CLI overrides are documented.
- [ ] Hard-coded environment-specific paths are eliminated or justified.
- [ ] No credentials/secrets are committed.
- [ ] Runtime state is separated from configuration.
- [ ] Temporary data has defined ownership.
- [ ] Dry-run does not modify persistent configuration.

## Exit Criteria

```text
Undocumented configuration sources = 0
Undocumented hard-coded environment dependencies = 0
Committed credentials/secrets = 0
```

- [ ] Configuration behavior is documented.
- [ ] Existing commands continue to operate using the new configuration model.

**Exit status:** `PASS`

---

# 10. Phase 7 — Filesystem & Data Safety

**Objective:** Make destructive and bulk operations predictable and recoverable.

## Entry Criteria

- [ ] Configuration model is stable.
- [ ] Destructive operations have been identified.
- [ ] Relevant data flows are documented.
- [ ] Test fixtures can be created safely.

## Measurable Completion Criteria

Every destructive operation has:

- [ ] path validation;
- [ ] input validation;
- [ ] existence/type checks where appropriate;
- [ ] predictable failure behavior;
- [ ] logging;
- [ ] dry-run support where appropriate.

Safety tests cover:

- [ ] empty path;
- [ ] nonexistent path;
- [ ] incorrect file type;
- [ ] permission failure;
- [ ] duplicate input;
- [ ] partial failure;
- [ ] interruption;
- [ ] dry-run;
- [ ] normal execution.

## Exit Criteria

```text
Untested destructive operations = 0
Known unsafe destructive paths = 0
```

- [ ] Bulk operations produce an understandable summary.
- [ ] Dry-run has been verified not to modify protected state.
- [ ] No HIGH-risk filesystem operation remains unreviewed.

**Exit status:** `PASS`

---

# 11. Phase 8 — Database Utilities

**Objective:** Make database operations explicit, testable, and safe.

## Entry Criteria

- [ ] Database-related commands have been identified.
- [ ] Database schema/data dependencies are documented.
- [ ] A safe isolated test database or fixture strategy exists.
- [ ] Production database will not be used for uncontrolled testing.

## Measurable Completion Criteria

- [ ] Connection configuration is centralized.
- [ ] Database/schema selection is explicit.
- [ ] Encoding behavior is documented.
- [ ] Import behavior is documented.
- [ ] Export behavior is documented.
- [ ] Error behavior is documented.
- [ ] Backup/rollback behavior is documented where applicable.
- [ ] Transactions are used where appropriate.
- [ ] Destructive SQL is explicitly identified.
- [ ] Database integration tests pass.

## Exit Criteria

```text
Database commands with passing integration tests / database commands = 100%
```

```text
Unreviewed destructive SQL operations = 0
```

- [ ] No production data is required to run the automated test suite.
- [ ] Database failure modes are controlled.
- [ ] Data-source-of-truth decisions are documented.

**Exit status:** `PASS`

---

# 12. Phase 9 — Testing

**Objective:** Establish confidence that refactoring preserves intended behavior.

## Entry Criteria

- [ ] Refactored commands exist.
- [ ] Critical workflows have been identified.
- [ ] Test fixtures can be isolated.
- [ ] Test execution can be automated.

## Measurable Completion Criteria

- [ ] Unit-test structure exists.
- [ ] Integration-test structure exists.
- [ ] Fixtures are isolated.
- [ ] Critical reusable functions have tests.
- [ ] Critical workflows have integration tests.
- [ ] Failure paths are tested.
- [ ] Dry-run behavior is tested.
- [ ] Tests work from a clean checkout.

Minimum targets:

```text
Critical workflow coverage = 100%
Critical destructive-operation coverage = 100%
Critical failure-path coverage = 100%
```

Initial general unit-test target:

```text
Minimum unit-test coverage = 80%
```

The 80% figure is a floor, not a substitute for testing critical behavior.

## Exit Criteria

```text
Failing automated tests = 0
Critical workflows without tests = 0
Critical destructive operations without tests = 0
```

- [ ] Test suite can be executed reproducibly.
- [ ] Test failures produce non-zero exit status.
- [ ] No test depends unintentionally on production data or developer-specific paths.

**Exit status:** `PASS`

---

# 13. Phase 10 — Documentation

**Objective:** Make the refactored project usable without relying on tribal knowledge.

## Entry Criteria

- [ ] Public commands are stable enough to document.
- [ ] Configuration model is stable.
- [ ] Architecture is documented.
- [ ] Major workflows are known.

## Measurable Completion Criteria

- [ ] README is current.
- [ ] `UserGuide.md` exists.
- [ ] `DEVELOPMENT.md` exists.
- [ ] `ARCHITECTURE.md` exists.
- [ ] 100% of public commands are documented.
- [ ] 100% of public options are documented.
- [ ] Installation/prerequisites are documented.
- [ ] Configuration is documented.
- [ ] Common failures are documented.
- [ ] Migration information exists for renamed commands.
- [ ] Documented examples have been tested.

## Exit Criteria

```text
Documented public commands / total public commands = 100%
Documented public options / total public options = 100%
```

- [ ] No documentation describes removed behavior as current.
- [ ] No public command is undocumented.
- [ ] Documentation can be followed from a clean checkout.

**Exit status:** `PASS`

---

# 14. Phase 11 — CI & Quality Gates

**Objective:** Prevent regression after the refactoring is complete.

## Entry Criteria

- [ ] Test suite exists.
- [ ] ShellCheck configuration exists.
- [ ] Repository structure is stable enough for automation.
- [ ] Required external dependencies are known.

## Measurable Completion Criteria

CI runs:

- [ ] shell syntax validation;
- [ ] ShellCheck;
- [ ] unit tests;
- [ ] integration tests where practical.

CI must:

- [ ] fail on syntax errors;
- [ ] fail on test failures;
- [ ] fail on unapproved quality violations;
- [ ] run from a clean checkout;
- [ ] provide understandable failure output.

## Exit Criteria

```text
Known failing CI jobs = 0
Required CI checks passing = 100%
```

- [ ] CI has been successfully executed against the refactored repository.
- [ ] No required quality check depends on a developer's local environment.

**Exit status:** `PASS`

---

# 15. Phase 12 — Command Naming & Public Interface

**Objective:** Establish a stable and understandable public CLI.

## Entry Criteria

- [ ] Public commands have been identified.
- [ ] Command responsibilities are stable.
- [ ] Documentation has been updated sufficiently to evaluate names.

## Measurable Completion Criteria

- [ ] Every public command has an intentional name.
- [ ] Naming follows one documented convention.
- [ ] Deprecated names are identified.
- [ ] Migration paths exist for renamed commands.
- [ ] No accidental `new`, `old`, `v2`, `tmp`, `final`, etc. names remain.
- [ ] `--help` output is consistent.
- [ ] Important exit-code behavior is documented.

## Exit Criteria

```text
Public commands conforming to naming convention / total public commands = 100%
```

- [ ] No unresolved accidental public interfaces remain.
- [ ] Renames have compatibility/migration handling where required.
- [ ] Documentation matches the final command names.

**Exit status:** `PASS`

---

# 16. Phase 13 — Legacy Removal

**Objective:** Remove obsolete implementation only after its replacement is proven.

## Entry Criteria

- [ ] Replacement implementation exists.
- [ ] Replacement implementation is tested.
- [ ] Replacement has been exercised successfully.
- [ ] References to legacy interfaces have been identified.
- [ ] Documentation has been migrated.

## Measurable Completion Criteria

For every deleted legacy item:

- [ ] replacement exists or deletion is explicitly justified;
- [ ] tests cover replacement behavior;
- [ ] callers have been migrated;
- [ ] documentation has been migrated;
- [ ] Git history records the reason for removal.

## Exit Criteria

```text
Legacy files deleted without documented reason = 0
Known references to deleted public interfaces = 0
Unverified legacy removals = 0
```

- [ ] Repository contains no known obsolete duplicate implementation.
- [ ] Final tree contains no unexplained temporary/debug artifacts.
- [ ] Full test suite passes after deletion.

**Exit status:** `PASS`

---

# 17. Final Acceptance Gate

The entire refactoring is complete only when:

```text
Phase 1   PASS
Phase 2   PASS
Phase 3   PASS
Phase 4   PASS
Phase 5   PASS
Phase 6   PASS
Phase 7   PASS
Phase 8   PASS
Phase 9   PASS
Phase 10  PASS
Phase 11  PASS
Phase 12  PASS
Phase 13  PASS
```

And:

```text
Shell syntax errors                  = 0
Undocumented ShellCheck violations  = 0
Failing automated tests              = 0
Known unsafe destructive operations  = 0
Undocumented configuration sources   = 0
Undocumented public commands         = 0
Undocumented public options         = 0
Committed secrets                    = 0
Unresolved HIGH-risk refactors       = 0
Unverified legacy removals           = 0
```

---

# 18. Phase Completion Record

Every phase must end with a recorded gate result.

```text
## Phase N Completion Record

Status: PASS / FAIL / BLOCKED

Date:
Starting Commit:
Completion Commit:

Entry Criteria:
- Passed:
- Failed:

Measurable Criteria:
- Passed:
- Failed:

Exit Criteria:
- Passed:
- Failed:

Automated Tests:
- Passed:
- Failed:

Risk Review:
- HIGH:
- MEDIUM:
- LOW:

Exceptions:
- None

Follow-up Items:
- None
```

A phase must **not** be marked `PASS` if any mandatory entry, measurable, or exit criterion is failed.

---

# 19. Phase Dependency Rule

Phases are sequential unless explicitly marked otherwise.

```text
Phase N = PASS
       ↓
Phase N+1 may become READY
       ↓
Phase N+1 starts
```

If a later phase exposes a problem in an earlier phase:

```text
Later Phase
    ↓
problem discovered
    ↓
create corrective work
    ↓
return to affected phase
