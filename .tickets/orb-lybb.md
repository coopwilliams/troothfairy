---
id: orb-lybb
status: closed
deps: []
links: []
created: 2026-03-17T01:33:11Z
type: task
priority: 2
assignee: coopwilliams
tags: [enhancement]
---
# PDF quoting skill for subagents

Build a tool that lets subagents accurately quote from PDFs without hallucinating. Workflow: agent finds PDF in knowledge_dirs, calls a helper to extract text (pdftotext), greps for relevant sections with page numbers, pages through ~500-token chunks to find exact passage, then programmatically copies the literal text into its response. Implemented as CLI commands (pdf-search, pdf-page, pdf-chunk). Agent cites source file, page number, and exact extracted text in a blockquote. Solves the LLM weakness of misquoting sources.

