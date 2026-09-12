# docs/archive/ — consumed and historical documents

Moved here 2026-09-12 during the post-Phase-4 cleanup. These documents
are **kept for provenance only** — none of them is a living instruction.
Their content is either absorbed into a living document (noted per file)
or describes a state of the repository that no longer exists.

| Document | Status | Where the content lives now |
|---|---|---|
| `REFACTORING_BLUEPRINT.md` | Superseded in part | Phase 1 inventory §3–9, ratified `docs/PHASE_02_TARGET_ARCHITECTURE.md`, `ARCHITECTURE.md` |
| `ebook-library-tools — Updated Refactoring Plan.md` | Consumed (Phases 1–4 executed) | The `PHASE_0*` documents are its deliverables; remaining phase guidance folded into `ARCHITECTURE.md` |
| `ebook-library-tools — Refactoring Plan with Phase Entry & Exit Criteria.md` | Consumed | Gates tracked in `docs/Measurable Phase Completion Criteria.md` |
| `BOOK_LIBRARY_MERGE_PLAN.md` | Implemented & shipped | `bin/books/books_merge.sh` + `bin/books/books_finalize.sh`, their configs and suites |
| `REPRESENTATION_PLAN.md` | Implemented & shipped | `myprivatelib` pipeline (`bin/library/*`), `docs/MultiLib_Flibusta_DB.md` |
| `COVERS_PLAN.md` | Resolved | Covers/annotations confirmed working end-to-end 2026-09-06 (see `CHANGELOG.md`); DB facts in `docs/MultiLib_Flibusta_DB.md` |
| `DO_IT_ongoing.md` | Completed assignment log | Every part resolved; history in `CHANGELOG.md` |
| `BookTracker Import — User Guide.md` | Belongs to the sibling project | Live copy maintained in **BookTracker-import**, not here |
| `NB_001-find-bookid-in-schema.md` | Absorbed | `docs/MultiLib_Flibusta_DB.md` §7 (md5 tier) and §9 (quick-reference SQL, also `data/sql/`) |
| `Flibusta_DB_findings.txt` | Absorbed | The md5-checksum matching idea is `docs/MultiLib_Flibusta_DB.md` §7.1 and the whole populate pipeline |

Do **not** update files in this folder. If something here turns out to
still matter, move the fact forward into the living document — not the
reverse.
