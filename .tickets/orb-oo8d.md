---
id: orb-oo8d
status: open
deps: []
links: []
created: 2026-03-21T18:08:12Z
type: task
priority: 2
assignee: coopwilliams
---
# Add more distinctive Obsidian CSS rendering for tagged and machine-response blocks

# Add more distinctive Obsidian CSS rendering for tagged and machine-response blocks

Improve the Obsidian-side visual styling for blocks that contain Troothfairy tags so machine-generated responses and tagged workflow states are easier to distinguish at a glance.

## Goals

- Add better CSS rules for blocks containing user tags and machine-response tags
- Make machine responses visually distinctive without harming readability
- Support clearer visual differentiation between user-authored prompts, machine responses, completion markers, failures, and related states
- Preserve compatibility with Obsidian rendering and existing vault usage

## Scope

- Review current tag patterns used in vault content (`#ƒ`, `#∆`, `#∑`, `#©`, `#$`, `#Ω`, `#¡`, etc.)
- Define a CSS strategy for styling tagged blocks, especially machine responses
- Implement the CSS in a way that is maintainable and easy to extend as new tags or block states are added
- Add notes or examples showing the intended visual distinctions

## Acceptance criteria

- Machine-response blocks are more visually distinctive in Obsidian
- Tagged block states are easier to scan and differentiate
- Styling is maintainable and extensible for future tag/state additions
- Add any needed examples, docs, or reproducible styling references


