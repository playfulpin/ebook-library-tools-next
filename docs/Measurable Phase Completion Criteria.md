# ebook-library-tools — Measurable Phase Completion Criteria

## Completion Rule

A phase is **COMPLETE** only when all mandatory criteria for that phase are satisfied.

A phase is **NOT COMPLETE** if:

- any mandatory deliverable is missing;
- any critical test fails;
- undocumented behavior changes remain;
- known high-risk issues remain unresolved;
- the repository cannot be returned to a clean, reproducible state.

Each phase should end with:

```text
PASS / FAIL
```

and a short completion record containing:

```text
Phase:
Status:
Commit:
Tests:
Known Exceptions:
Follow-up Items:
```

---

# Phase 1 — Repository Inventory & Dependency Map

## Mandatory criteria

- [ ] 100% of tracked source files are inventoried.
- [ ] 100% of executable scripts are identified.
- [ ] 100% of significant configuration files are identified.
- [ ] 100% of user-facing commands are identified.
- [ ] 100% of executable scripts have identified callers/dependents, or are explicitly marked as entry points.
- [ ] External command dependencies are recorded.
- [ ] Environment-variable dependencies are recorded.
- [ ] Configuration sources are recorded.
- [ ] Significant input/output paths are recorded.
- [ ] Every significant file has one disposition:
  `KEEP`, `RENAME`, `MOVE`, `MERGE`, `SPLIT`, `REWRITE`, `DEPRECATE`, or `DELETE`.
- [ ] No unexplained duplicate/obsolete implementation remains unidentified.
- [ ] `REPOSITORY_INVENTORY.md` exists.
- [ ] `DEPENDENCY_MAP.md` exists.
- [ ] `DATA_FLOW.md` exists.
- [ ] `REFACTORING_DECISIONS.md` exists.

## Quantitative gate

```text
Inventory coverage = inventoried significant files / total significant files

Required: 100%
```

**Phase 1 passes only at 100%.**

---

# Phase 2 — Target Architecture

## Mandatory criteria

- [ ] Target directory structure is documented.
- [ ] Every current directory has a target disposition.
- [ ] Responsibilities of `bin/`, `lib/`, `config/`, `tests/`, and `docs/` are documented.
- [ ] User-facing commands are explicitly identified.
- [ ] Reusable library responsibilities are defined.
- [ ] Configuration ownership is defined.
- [ ] Runtime-state ownership is defined.
- [ ] Data-flow boundaries are documented.
- [ ] Dependency direction is documented.
- [ ] No circular dependency is intentionally introduced.
- [ ] Architecture document exists.

## Architecture gate

Every significant component must answer:

```text
Who calls it?
What does it own?
What does it depend on?
What does it modify?
Where are its tests?
```

**Required: 100% of significant components have answers.**

---

# Phase 3 — Common Shell Infrastructure

## Mandatory criteria

- [ ] Common initialization is centralized.
- [ ] Project-root/script-location detection is centralized.
- [ ] Logging implementation is centralized.
- [ ] Progress implementation is centralized.
- [ ] Common CLI conventions are documented.
- [ ] Common error-handling conventions are documented.
- [ ] No new duplicate implementations of common functionality exist.
- [ ] All converted scripts use the common infrastructure.
- [ ] Shell syntax validation passes for all converted scripts.
- [ ] ShellCheck passes for all converted scripts, or every exception is documented and justified.

## Quantitative gate

```text
Converted scripts using common infrastructure / total converted scripts

Required: 100%
```

```text
Undocumented ShellCheck warnings

Required: 0
```

---

# Phase 4 — Individual Command Refactoring

Each command is treated as an independent completion unit.

## Per-command criteria

- [ ] CLI arguments are parsed in a defined location.
- [ ] Configuration loading is separated from business logic.
- [ ] Input validation occurs before destructive work.
- [ ] Business logic is implemented in reusable functions where appropriate.
- [ ] Logging uses the common implementation.
- [ ] Progress reporting uses the common implementation where required.
- [ ] Errors return predictable non-zero status.
- [ ] Temporary resources are cleaned up.
- [ ] No unnecessary global state remains.
- [ ] No duplicated common logic remains.
- [ ] `--help` works.
- [ ] Normal execution works.
- [ ] Invalid input produces a controlled failure.
- [ ] Dry-run behavior works where applicable.
- [ ] Tests exist for critical behavior.

## Quantitative gate

For each command:

```text
Required command test pass rate = 100%
```

Overall:

```text
Completed commands / planned commands = 100%
```

A phase cannot pass because “most commands work.”

---

# Phase 5 — Function Headers & Coding Standards

## Mandatory criteria

- [ ] All production shell files have standardized file headers.
- [ ] All non-trivial functions have standardized function headers.
- [ ] Arguments are documented.
- [ ] Return behavior is documented.
- [ ] Side effects are documented where relevant.
- [ ] Naming conventions are consistent.
- [ ] Variable quoting has been reviewed.
- [ ] ShellCheck passes or documented exceptions exist.
- [ ] No newly introduced style violations remain.

## Quantitative gate

```text
Production functions meeting header standard / production non-trivial functions

Required: 100%
```

```text
Undocumented coding-standard exceptions

Required: 0
```

---

# Phase 6 — Configuration Cleanup

## Mandatory criteria

- [ ] All persistent configuration sources are identified.
- [ ] Configuration has one documented ownership model.
- [ ] Defaults are explicitly defined.
- [ ] Environment overrides are documented.
- [ ] CLI overrides are documented where supported.
- [ ] Hard-coded environment-specific paths are eliminated or explicitly justified.
- [ ] Secrets are not committed to the repository.
- [ ] Runtime state is not stored as configuration.
- [ ] Temporary data has a defined location/lifecycle.
- [ ] Dry-run does not modify persistent configuration.

## Quantitative gate

```text
Undocumented configuration sources = 0
Undocumented hard-coded environment dependencies = 0
Committed credentials/secrets = 0
```

---

# Phase 7 — Filesystem & Data Safety

## Mandatory criteria

Every destructive operation must have:

- [ ] path validation;
- [ ] input validation;
- [ ] appropriate existence checks;
- [ ] predictable failure behavior;
- [ ] logging;
- [ ] dry-run support where appropriate.

## Safety tests

The following must be tested where applicable:

- [ ] empty path;
- [ ] nonexistent path;
- [ ] wrong file type;
- [ ] permission failure;
- [ ] duplicate input;
- [ ] partial failure;
- [ ] interrupted execution;
- [ ] dry-run;
- [ ] normal execution.

## Quantitative gate

```text
Untested destructive operations = 0
```

```text
Known unsafe destructive paths = 0
```

---

# Phase 8 — Database Utilities

## Mandatory criteria

- [ ] Connection configuration is centralized.
- [ ] Database/schema selection is explicit.
- [ ] Encoding behavior is documented.
- [ ] Import behavior is documented.
- [ ] Export behavior is documented.
- [ ] Failure behavior is documented.
- [ ] Backup/rollback strategy is documented where applicable.
- [ ] Transactions are used where appropriate.
- [ ] Destructive database operations require explicit intent.
- [ ] Database tests use isolated test data.
- [ ] Production data is never used as an uncontrolled test fixture.

## Quantitative gate

```text
Database commands with passing integration tests / database commands

Required: 100%
```

```text
Unreviewed destructive SQL operations = 0
```

---

# Phase 9 — Testing

## Mandatory criteria

- [ ] Unit-test structure exists.
- [ ] Integration-test structure exists.
- [ ] Test fixtures are isolated from production data.
- [ ] Critical reusable functions have tests.
- [ ] Critical workflows have integration tests.
- [ ] Failure paths are tested.
- [ ] Dry-run behavior is tested.
- [ ] Tests are reproducible from a clean checkout.
- [ ] Tests return a non-zero status on failure.

## Minimum quantitative targets

```text
Critical workflows covered: 100%
Critical destructive operations covered: 100%
Critical failure paths covered: 100%
```

For ordinary function coverage, establish a project-specific target, e.g.:

```text
Minimum unit-test coverage: 80%
```

The exact percentage can be adjusted after Phase 1 reveals the project's actual complexity.

**Coverage alone does not determine completion.** Critical behavior must be covered regardless of percentage.

---

# Phase 10 — Documentation

## Mandatory criteria

- [ ] README describes installation and basic usage.
- [ ] User guide exists.
- [ ] Developer guide exists.
- [ ] Architecture documentation exists.
- [ ] Every public command is documented.
- [ ] Every public option is documented.
- [ ] Examples have been tested.
- [ ] Prerequisites are documented.
- [ ] Configuration is documented.
- [ ] Common failures are documented.
- [ ] Migration information exists for renamed commands.

## Quantitative gate

```text
Documented public commands / total public commands

Required: 100%
```

```text
Documented public CLI options / total public CLI options

Required: 100%
```

---

# Phase 11 — CI & Quality Gates

## Mandatory criteria

CI must automatically run:

- [ ] shell syntax validation;
- [ ] ShellCheck;
- [ ] unit tests;
- [ ] integration tests where practical.

CI must:

- [ ] fail on test failure;
- [ ] fail on syntax failure;
- [ ] fail on unapproved quality violations;
- [ ] run from a clean checkout;
- [ ] produce understandable failure output.

## Quantitative gate

```text
Required CI checks passing on default branch: 100%
```

```text
Known failing CI jobs: 0
```

---

# Phase 12 — Command Naming & Public Interface

## Mandatory criteria

- [ ] Every public command has an intentional name.
- [ ] Naming follows one documented convention.
- [ ] Deprecated names are explicitly documented.
- [ ] Migration paths exist for renamed commands.
- [ ] No accidental `new`, `old`, `v2`, `tmp`, `final`, etc. names remain.
- [ ] `--help` output is consistent.
- [ ] Exit-code behavior is documented where important.

## Quantitative gate

```text
Public commands conforming to naming convention / total public commands

Required: 100%
```

---

# Phase 13 — Legacy Removal

## Mandatory criteria

Before deleting any legacy implementation:

- [ ] replacement implementation exists;
- [ ] replacement has tests;
- [ ] replacement has been used successfully;
- [ ] dependencies on the old implementation have been checked;
- [ ] documentation no longer depends on the old implementation;
- [ ] Git history preserves the reason for removal.

## Quantitative gate

```text
Legacy files deleted without documented replacement/reason = 0
```

```text
Known references to deleted public interfaces = 0
```

---

# Final Refactoring Acceptance Gate

The refactoring is considered **COMPLETE** only when all of the following are true:

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

Additionally:

```text
Shell syntax errors                  = 0
Undocumented ShellCheck violations  = 0
Failing automated tests              = 0
Known unsafe destructive operations  = 0
Undocumented configuration sources   = 0
Undocumented public commands         = 0
Undocumented deleted interfaces     = 0
Committed secrets                    = 0
Unresolved HIGH-risk refactors       = 0
```

---

# Phase Completion Record

At the end of every phase, create a short record:

```text
## Phase N Completion Record

Status: PASS / FAIL

Date:
Commit:

Mandatory Criteria:
- Passed:
- Failed:

Automated Tests:
- Passed:
- Failed:

Exceptions:
- None

Follow-up Items:
- None
```

A phase should **not** be marked complete merely because the code "looks good."

The completion status must be supported by measurable evidence.