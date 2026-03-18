---
id: orb-wt0i
status: open
deps: []
links: []
created: 2026-03-18T03:07:41Z
type: bug
priority: 2
assignee: coopwilliams
---
# Fix install.sh install_if_missing function

install_if_missing takes a single cmd parameter but is called with multiple packages (e.g. install_if_missing pandoc poppler ffmpeg rga). Needs to either loop over arguments or be called separately per package. install.sh is untested overall — this is part of broader install script validation.

