# Security

## Reporting a vulnerability

Please report security problems privately to **[CONTACT EMAIL]**, not in a public issue.

Include what you found, how to reproduce it, which version and macOS you use, and what someone could do with it.
Please don't access other people's data, rooms or devices, and don't run tests that slow down or break
pluck.tools for others. Test against your own Mac, your own review links and your own rooms.

## What happens next

Pluck is made by one person, so these are goals, not guarantees:

| When | What |
| --- | --- |
| 3 working days | I confirm I received your report. |
| 10 working days | I tell you whether I can reproduce it and how serious I think it is. |
| 30 days (serious issues: as fast as possible) | A fix is released, or I explain why it takes longer. |

I'll credit you in the release notes if you'd like. Please give me a chance to release a fix before you publish
details; 90 days at most, or earlier once the fix is out.

## Supported versions

Only the latest release of Pluck and Pluck Studio gets security fixes. The apps update themselves; please keep
updates on. The Pluck Review host for NAS and servers is supported in the version that matches the latest app.

## In scope

- Pluck and Pluck Studio (the macOS apps) and their helper tools in this repository
  (pluck-review, pluck-iroh, pluck-tunnel and the others under `Helpers/`)
- The Pluck Review page and signaling server at pluck.tools (`/r/…`, `/signal/…`)
- Edit Anywhere pairing and connections

Out of scope: third-party tools Pluck downloads (yt-dlp, FFmpeg, Deno, AI models) unless the problem is in how
Pluck uses them; please report those to their own projects. Also out of scope: Cloudflare, GitHub, iroh's public
relays and Tailscale themselves.
