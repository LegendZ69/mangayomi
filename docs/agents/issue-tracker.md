# Issue tracker: Local Markdown

Issues and specs for `LegendZ69/mangayomi` live in this repository under `.scratch/`. GitHub Issues is disabled on this fork at setup time. Inherited issue templates and upstream support links do not change this repository's task destination.

## Conventions

- Use one directory per feature or effort: `.scratch/<feature-slug>/`.
- Save the spec as `spec.md` in that directory.
- Save each implementation ticket separately under `issues/<NN>-<slug>.md`, numbered from `01` within the effort. Allocate a new number rather than overwriting an existing ticket.
- Give each ticket a title, a `Status:` line, its goal, and acceptance criteria. Use `open`, `claimed`, or `resolved` for status; new tickets start `open`.
- Append comments and conversation history under `## Comments`.
- Resolve a ticket by recording the outcome and validation evidence, then setting `Status: resolved`. Retain the file and its history.

## Publish and fetch

When a skill says "publish to the issue tracker", create the corresponding spec or ticket file under `.scratch/<feature-slug>/`, creating directories as needed.

When a skill says "fetch the relevant ticket", read its file. Resolve a bare ticket number within the current effort; ask for the effort or path if that number is ambiguous.

Keep these Markdown files with the project so another session can continue from them. Include relevant files in the feature's version-control changes.

## Wayfinding operations

The map is `.scratch/<effort>/map.md`, with Notes, Decisions-so-far, and Fog sections. Each child is a separate `issues/<NN>-<slug>.md` file in that effort.

- **Create a child:** state the question or task, set `Status: open`, and add `Type: research`, `prototype`, `grilling`, or `task`.
- **Record dependencies:** add `Blocked by: NN, NN` near the top, using ticket numbers from the same effort. Omit the line when there are no blockers. A missing blocker file remains unresolved.
- **Find the frontier:** scan children in numeric order for an `open` ticket whose blockers are all `resolved`. Tickets marked `claimed` are already being worked on.
- **Claim:** set `Status: claimed` and save before starting work.
- **Resolve:** append the result under `## Answer`, set `Status: resolved`, and add a short summary with a relative link to the child in the map's Decisions-so-far section.
