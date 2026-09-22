# Monocle OS — discovery

A loan operating system for a private real-estate lender, from the first email a
loan officer sends to the wire that funds it.

**This folder is the discovery record.** Everything we have been told, written down
in the order the work actually happens, turned into something a team can build
from. It is derived from the client's own process document, their written answers,
their field workbook and eight recorded working sessions between 23 July and 15
September 2026.

**It is not a proposal.** There are no prices, no effort estimates and no
commercial terms anywhere in this folder, by design.

---

## Start here

| | | |
|---|---|---|
| **Want the whole picture in one document** | [`00-what-we-are-building.md`](00-what-we-are-building.md) | The engines, then the loan's journey stage by stage — who acts, what they fill in, what it generates, who it goes to, what it syncs with, what it refuses. Plus every open question |
| **Explaining it to someone new** | [`12-plain-english-guide.md`](12-plain-english-guide.md) | The whole project in plain English, no lending background assumed — every permutation and every fork walked through with a named person and a real situation |
| **New to the project** | [`01-the-process.md`](01-the-process.md) | The whole thing in plain language — glossary, then every stage step by step. One sitting, about forty minutes |
| **Want the picture, not the prose** | [`02-the-flowchart.md`](02-the-flowchart.md) | 17 diagrams: the journey, the roles, every stage, the needs list, the document lifecycle, every email. Renders in the browser on GitHub |
| **Building it** | [`08-database.md`](08-database.md) and [`database/schema.sql`](database/schema.sql) | 59 tables, and runnable PostgreSQL |
| **Deciding something** | [`11-open-questions.md`](11-open-questions.md) | What is still unanswered, and what we assumed meanwhile |

---

## Everything, in reading order

**The whole thing**

| | |
|---|---|
| [`00-what-we-are-building.md`](00-what-we-are-building.md) | The reconciliation of all discovery: seven foundational engines, six stages plus On-Hold, what changed in the latest round, and all 23 open questions |

**The process**

| | |
|---|---|
| [`01-the-process.md`](01-the-process.md) | The whole thing, end to end, in plain language |
| [`02-the-flowchart.md`](02-the-flowchart.md) | The same process as diagrams, with 16 questions still to settle |
| [`03-scope.md`](03-scope.md) | What is in, what is out, and the three tests anything new has to pass |
| [`04-process-steps.md`](04-process-steps.md) | Each step in the client's own numbering, and what it became |
| [`12-plain-english-guide.md`](12-plain-english-guide.md) | The same process in plain English, with a worked example for every permutation and every fork. Derived from the documents above; where they differ, they win |

**The detail**

| | |
|---|---|
| [`05-roles.md`](05-roles.md) | Seven roles, what each sees and does, and the four rules the system refuses to break |
| [`06-communications.md`](06-communications.md) | Every email: who sends it, to whom, when, and what it carries |
| [`07-data-fields.md`](07-data-fields.md) | Every field, the tab it lives on, and the stage at which it appears |

**The build**

| | |
|---|---|
| [`08-database.md`](08-database.md) | The schema, one diagram per domain |
| [`08-database.html`](08-database.html) | The same thing for non-technical review — a map, a walk through the process, every table in plain English. Download and open it; GitHub shows HTML as source |
| [`database/`](database/) | Runnable PostgreSQL, the reporting views, and the reasoning behind the eight schema decisions |
| [`09-architecture-and-hosting.md`](09-architecture-and-hosting.md) | How it runs, and why each piece is there |
| [`13-system-design.md`](13-system-design.md) | How the application is built — the stage machine and its four gates, what enforces the permission matrix, the API surface, and the work that leaves the platform |

**The record**

| | |
|---|---|
| [`10-decisions.md`](10-decisions.md) | 46 numbered decisions, each citing the source that settled it |
| [`11-open-questions.md`](11-open-questions.md) | 34 open questions, each with what we did in the meantime |
| [`client-inputs/`](client-inputs/) | The client's own written process material, verbatim |

---

## How to read any of it

**Three rules govern every line in this folder.**

1. **The client decides.** They own the process; we are writing down what they told
   us, not what we would design.
2. **Later beats earlier.** A ruling on a later call supersedes an earlier document,
   always. Where two sources conflict, the newer one wins and the conflict is
   recorded in [`10-decisions.md`](10-decisions.md).
3. **Sources beat inference.** Where no source settles something, it is an open
   question — not a judgement call. Every one of those is in
   [`11-open-questions.md`](11-open-questions.md) with the assumption we made
   meanwhile, so it can be corrected rather than discovered later.

**The vocabulary is the client's, exactly.** Repeat Borrower, not repeat client. UW
Material, not underwriting. Pulse, Needs List, Kick-off Email, No Fly List, Scrub,
Feasibility, Track Record, VOM, Payoff, AMC. Those words appear on screen and in
the code for a reason: the team already speaks them.

**Nothing here is ever late.** There are no SLAs, no due dates and no overdue
state anywhere in the process, because the client was explicit that there are
none — every loan has its own delay points outside anyone's control. Days in
status is the only timing signal.

---

## Where the discovery stands

| | |
|---|---|
| Stages, statuses and the moves between them | Settled |
| The approval chain, the LOI package, the Needs List rules | Settled |
| The document lifecycle and the three review layers | Settled |
| Every email, its sender and its recipients | Settled as of the 15 September note |
| The database | Drafted from the above, verified against PostgreSQL |
| The closing and funding process | **Settled 17 September** — the full post-Lightning-Docs sequence arrived |
| The flowchart | **Signed off by the client, 17 September** |
| **23 open questions, in [`00-what-we-are-building.md`](00-what-we-are-building.md) Part 4** | **Four of them change the shape of the build** |

They are ordered by weight: four change the shape of the build, ten change a
diagram or a screen, nine settle a field or a name. The four at the top are the
next thing that moves this forward.

---

## What is held back, and why

The working material behind this folder stays in the private build repository:

- **Verbatim call recordings.** Eight sessions, candid throughout — including
  remarks about the client's own team. Ours to hold, not to publish.
- **The live pipeline extract.** The field workbook carries 29 real loans with
  borrower property addresses, amounts and rates. Real customer data does not go in
  a public folder.
- **Delivery and commercial material.** Plans, estimates, scope of work.

Every conclusion those sources produced is in this folder, and every document cites
the session or note it came from by date, so nothing is asserted without a source.
If you need to see a source itself, ask.
