# Compositor Pro Documentation

This directory contains architectural guides, operational references, subsystem contracts, and international localized READMEs for Compositor Pro.

---

## Core Guides & References

- [adoption.md](adoption.md) — Architectural integration notes and migration guide for HyperFrames catalog, CLI, and templating into Compositor Pro.
- [HeadlessRendering.md](HeadlessRendering.md) — CLI commands, Docker execution, and headless CI export jobs.
- [external-agent-integration.md](external-agent-integration.md) — MCP Server integration over HTTP for external agents (Claude Code, Codex, OpenCode).
- [agent-professional-video-architecture.md](agent-professional-video-architecture.md) — Technical design and editorial pipeline of the agent-driven video production system.
- [human-confirmation.md](human-confirmation.md) — Manual QA checklist for installed app verification.
- [delegation-verification.md](delegation-verification.md) — Experimental latency and lifecycle verification protocol for subagent delegation.

---

## Subsystem Contracts (`docs/contracts/`)

Detailed domain contracts, concurrency invariants, and mutation rules for core features:

### Storyboard & Editorial Planning
- [explainer-storyboard-review.md](contracts/explainer-storyboard-review.md) — Storyboard review panel, approval phases, and revision invalidation.
- [storyboard-preview.md](contracts/storyboard-preview.md) — Animatic sequential preview without live timeline mutations.
- [explainer-narration-timing.md](contracts/explainer-narration-timing.md) — Speech duration measurement and transcript alignment contract.
- [approved-narration-intent.md](contracts/approved-narration-intent.md) — Separation of authored narrator intent from timing resolution.
- [explainer-source-ledger.md](contracts/explainer-source-ledger.md) — Factual claim and evidence ledger linking sources to script beats.
- [explainer-reference-recipes.md](contracts/explainer-reference-recipes.md) — Structural and stylistic recipe extraction from reference films.

### Media Identity, Uniqueness & Graphics
- [explainer-media-identity.md](contracts/explainer-media-identity.md) — SHA-256 byte input identity and provenance tracking.
- [explainer-visual-occurrences.md](contracts/explainer-visual-occurrences.md) — Whole-output occurrence calculation and nested carrier expansion.
- [explainer-export-uniqueness-gate.md](contracts/explainer-export-uniqueness-gate.md) — Preflight delivery gate enforcing no-repeat visual rules.
- [stock-source-diversity.md](contracts/stock-source-diversity.md) — Stock media pagination and exclusion filters.
- [map-scenes.md](contracts/map-scenes.md) — Geographic vector map scene authoring (`build_map_scene`).
- [evidence-graphics.md](contracts/evidence-graphics.md) — Typed, sourced charts and evidence cards (`build_graphic_scene`).

### Captions, Subagents & Generation
- [caption-styles.md](contracts/caption-styles.md) — Curated caption style presets and font scaling rules.
- [caption-edit-lifecycle.md](contracts/caption-edit-lifecycle.md) — Asynchronous caption task lifecycle and coordinator admission.
- [caption-translation.md](contracts/caption-translation.md) — Multilingual caption translation pipeline.
- [generation-lifecycle.md](contracts/generation-lifecycle.md) — Remote/local media generation job states and recovery.
- [agent-delegation.md](contracts/agent-delegation.md) — Parallel subagent task batching (`delegate_work`).

### Project Lifecycle & Package Coordination
- [project-package-lifecycle.md](contracts/project-package-lifecycle.md) — `.compositorpro` package coordination, mutation admission, and I/O fences.
- [project-close-confirmation.md](contracts/project-close-confirmation.md) — Coordinated project closing, save drains, and cancellation safety.
- [project-document-background-work.md](contracts/project-document-background-work.md) — Document thumbnail caching and media restore tasks.
- [project-registry-persistence.md](contracts/project-registry-persistence.md) — Authoritative project registry persistence.
- [project-plan-save.md](contracts/project-plan-save.md) — Immutable snapshot encoding during document saves.
- [project-media-undo-rebase.md](contracts/project-media-undo-rebase.md) — Media undo rebasing across Save As operations.

---

## Archived Audits & Backlogs (`docs/archive/`)

Historical investigation notes, completed technical backlogs, and point-in-time feasibility studies:
- [agent-video-quality-engineering-backlog.md](archive/agent-video-quality-engineering-backlog.md) — Initial engineering backlog for prompt-to-video quality (superseded).
- [prompt-to-video-technical-todo.md](archive/prompt-to-video-technical-todo.md) — Completed P0–P2 prompt-to-video quality milestone and manual test protocols.
- [malaysia-chip-explainer-capability-audit.md](archive/malaysia-chip-explainer-capability-audit.md) — Point-in-time reference audit (November 2026).
- [zero-service-cost-video-audit.md](archive/zero-service-cost-video-audit.md) — $0-cloud-cost editing feasibility audit (November 2026).
- [local-finishing.md](archive/local-finishing.md) — Local finishing analysis (November 2026).

---

## International Readmes (`docs/readme/`)

Localized translations of the project `README.md` are located in [`docs/readme/`](readme/):
Available in Arabic, Bengali, Spanish, French, Hindi, Italian, Japanese, Korean, Portuguese (Brazil), Russian, Turkish, Vietnamese, Simplified Chinese, and Traditional Chinese.

