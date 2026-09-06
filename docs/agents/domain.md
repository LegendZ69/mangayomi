# Domain docs

Mangayomi uses a single-context layout. The Flutter app and its native components share the repository's domain documentation.

## Before exploring

- Read root `CONTEXT.md` for domain terms and their meanings.
- Read the decisions in root `docs/adr/` that apply to the area being changed.
- If a root `CONTEXT-MAP.md` is introduced later, follow it to the context documents relevant to the task.

If these files or directories do not exist, continue silently. Create documentation when a term or decision is actually resolved; setup does not require placeholder documents. The `domain-modeling` skill can maintain them when available.

## Record terminology and decisions

- Keep the shared glossary in root `CONTEXT.md`.
- Save architecture decisions in `docs/adr/<NNNN>-<decision-slug>.md`, using the next available number and preserving existing decisions.
- Use the glossary's terms in issue titles, design discussions, code, and tests. If a needed concept has no term, check the project's existing language before introducing one.
- If a proposal conflicts with an ADR, identify the decision and explain why it should be reconsidered before changing course.
