# Desktop page design acceptance checklist

This is a renderer-design checklist, not a claim that every capability is accepted. Keep existing project isolation, frozen-approval and stale-response guards when changing layout.

## Sessions

- Default: searchable recent sessions, provider/state filters, one concise source-status note.
- Primary action: open a session row and read its detail drawer.
- Secondary: refresh, import project, history and agent-loop views belong in an overflow menu or a tab-specific control.
- Detail: messages, source identity, plans and relations may use disclosure sections; never show private source text outside its guard.
- Preserve: `#btn-refresh-sessions`, `#btn-add-project-agents`, session-row handlers, `sessions.refresh` project/discovery boundary, history pagination and stale guards.

## Workflows

- Default list tab: workflow name, enabled state, trigger and latest meaningful run state.
- Primary action: `#btn-new-workflow`.
- Secondary: validation, planning, prompt builder and starter templates must be grouped under creation/more controls. Each tab owns its contextual action.
- Tabs: Runs shows run review; Plans shows review/clarify; Schedules shows timing; Artifacts shows delivered output; Health shows observed findings and proposals.
- Preserve: dry-run distinction; exact frozen approval arguments; `#btn-plan-workflow`, `#btn-build-wf-prompt`, starter-template handlers; approval/recovery and project/version/hash checks.

## Memory

- Default: active project memory with candidate count and search.
- Primary action: inspect/review a candidate, not create arbitrary model memory.
- Secondary: scope/type filters, archive, import/export and index diagnostics go in filter/more/detail UI.
- Detail: source message, provenance and lifecycle are read-only; user body editing remains separately marked.
- Preserve: private/candidate exclusion from Recall; source identity checks; `memory.save` review path; no automatic activation.

## Setup

- Default: a compact project configuration inventory with scan completeness and actionable warnings.
- Primary action: scan/refresh current project.
- Secondary: source history, diff, relations and raw metadata in tabs or detail drawer.
- Preserve: scan must not execute Hooks/MCP; sanitization and source identity; no arbitrary path access through renderer.

## Approvals

- Default: pending approvals only, ordered by urgency/expiry; card shows intent, affected project/relative path and risk.
- Primary action: inspect then approve or reject exactly one frozen item.
- Secondary: full content, argv, hash and technical recovery data under disclosure.
- Preserve: `approvals.decide` exact `id`, `snapshotHash`, decision; displayed-approval cache gate; expired error must refresh authoritative list and never emit success; no pre-click list read that changes expiry.

## Usage

- Default: selected provider/window, observation time, available/unknown state and clearly separated token logs vs account quota.
- Primary action: change provider/window only when useful.
- Secondary: raw buckets, stale evidence and source diagnostics under disclosure.
- Preserve: unavailable is not zero; no invented price, model or quota; read-only usage/daemon calls.

## Improve

- Default: actionable reviewed suggestions with evidence, current state and project scope.
- Primary action: open one suggestion for evidence-first review.
- Secondary: analysis trigger, filters, history and undo in contextual menus/detail.
- Detail: show proposed diff and source evidence before any Apply button.
- Preserve: model/proposal result does not imply success; Apply/Undo hash and project guard; no automatic application.

## Lab

- Default: experiment list and explicit outcome (including Inconclusive/Reject), with one `new experiment` action.
- Primary action: create a frozen comparison or review one pending experiment.
- Secondary: Recall variant, regression evidence, promotion and raw verifier output belong to experiment detail/review steps.
- Preserve: separate strict OFF from no-memory legacy semantics; Recall source/lifecycle/project revalidation; lab execution only after explicit approval; no provider run in renderer fixtures.

## Settings

- Default: language and notification preferences with one visible save action.
- Primary action: save changed preferences.
- Secondary: sound preview, launch-at-login, daemon and connectors are separate advanced/local-service groups, not peers of language.
- Preserve: settings draft while asynchronous reads settle; `#setting-locale`, `#btn-save-settings`, allowed three sound-preview kinds; daemon/connector actions retain local identity and approval boundaries.

## Shared drawers and modals

- A header may retain at most the page title, short status and one primary action at narrow widths. Never let action buttons shrink title into a vertical column.
- Close affordances need stable IDs plus listeners or `[data-close-modal]`; no inline `onclick` reliance.
- Detail drawers may collapse raw JSON, hashes and long paths, but must retain accessible labels and exact approval values before a decision.
- Preserve modal/drawer epoch, project/page/run guards. Late responses must not open, populate or overwrite a new page, project, drawer or user edit.
