# Security policy

## Reporting a vulnerability

Report vulnerabilities through GitHub's private vulnerability reporting on this repository:
**Security tab → "Report a vulnerability"**. You should receive an acknowledgement within
72 hours.

Do not open public issues or pull requests for security reports.

## Scope

The contracts under `src/`.

Before reporting, read [`docs/known-issues.md`](docs/known-issues.md), the accepted-risk register.
Behaviours recorded there as `KI-*` items are known, analysed, and accepted; reports that restate
them will be closed with a pointer to the entry.

Findings against the dependency revisions pinned in `foundry.lock` (`lib/`) belong with those
projects; a report here is welcome only if this repository's use of the dependency is what makes
the finding exploitable.

## Status

The contracts have been through three independent security reviews; the reports and the
finding-by-finding response are linked from the README. Confirmed reports are fixed on `main`
and, where the behaviour is accepted instead, recorded in the known-issues register. There is no
bug bounty programme at this time.
