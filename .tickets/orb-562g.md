---
id: orb-562g
status: closed
deps: [orb-6urg, orb-sbtg]
links: []
created: 2026-03-16T19:56:21Z
type: task
priority: 2
assignee: coopwilliams
tags: [test]
---
# End-to-end test

Write a sample .md file with one of each tag type (#ƒ #∆ #∑ #©), run the full pipeline (fswatch -> dispatcher -> orchestrator -> subagents), and verify: open tags replaced with correct completion tags, agent responses nested correctly under each block, #Ω+tag prefix present, sources use #¬, no blacklisted domains linked. Also test failure case: trigger #¡ marking.

