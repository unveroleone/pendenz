---
name: agent-loop
description: Triage the owner's new Pendenz items and carry each one through questions, a brief, the work and closing it, with the exact tool calls. Use when items wait in stage new, when the owner answers a question about an item or says to start one, and when the work on an item is finished.
---

# The Pendenz agent loop

Call shapes (the tools reject any other field name):

- `list_items {"stage": "new"}`
- `update_item {"id": "P-40", "version": 2, "key": "triage-P-40-v2", "changes": {"agent_stage": "none"}}`
- `add_comment {"id": "P-40", "body": "Questions: ...", "key": "triage-P-40-q"}`
