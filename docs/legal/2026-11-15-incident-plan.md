# Incident plan: security problems and data breaches

For: the publisher of Pluck / Pluck Studio / pluck.tools / Pluck Review (an individual in Belgium).
Status: draft, 2026-11-15. Have a Belgian lawyer check the legal parts once. Keep this file short enough to use
in a hurry.

Background, inventory and the record of processing: `2026-11-15-liability-and-privacy.md` (same folder).

## What counts

- **Data breach (GDPR art. 4(12))**: personal data that I am responsible for is lost, leaked, changed, or seen by
  someone who shouldn't. For me that is mainly: Worker/Room/RelayBudget state, Cloudflare logs (IP addresses),
  donation and email data, and anything a bug causes the Worker to store or log that it shouldn't.
- **Security incident without personal data**: a leaked relay token or TURN key, a bad release, a compromised
  GitHub account or signing certificate, a vulnerability in the apps.
- Data on an **editor's** Mac or NAS (client names, emails, comments, files) is the editor's. A bug in Pluck that
  exposes it is still my incident to fix and to tell editors about, but the GDPR notification to the
  authority is the editor's duty (they are the controller). Help them with the facts.

## The first 72 hours

The clock (GDPR art. 33) starts when I'm reasonably sure personal data I control was breached, not when I
first hear a rumour. Write down the time.

### Hour 0 to 4: stop it

1. Start a log: `docs/legal/incidents/<date>-<short-name>.md` (create the folder). Note every step with the
   time. GDPR art. 33(5) requires a record of every breach, even ones I don't have to report.
2. Contain, as needed (pick what fits):
   - **Signaling/Worker misbehaving**: deploy the last known good version (`deploy/deploy.sh` from a clean
     checkout), or in the Cloudflare dashboard remove the Worker route for `/signal/*` so Review stops instead of
     leaking. Review links simply go "offline"; nothing is lost on editors' Macs.
   - **Relay token leaked** (`OWNER_RELAY_TOKEN`): make a new one
     (`openssl rand -base64 32 | tr '+/' '-_' | tr -d '='`), set it in Cloudflare (Workers & Pages >
     pluck-tools > Settings > Variables and Secrets), in Pluck (Settings > Review > Relay token) and in each
     host's `PLUCK_RELAY_TOKEN`. The old one stops working at once.
   - **TURN key leaked** (`TURN_KEY_ID` / `TURN_KEY_API_TOKEN`): in Cloudflare Realtime > TURN, delete the key
     and create a new one; update both secrets. Credentials already handed out die within their 4-hour TTL.
     Check Notifications > Billing: Cloudflare has no spending cap.
   - **Analytics token leaked** (`CF_ANALYTICS_TOKEN`): roll it in My Profile > API Tokens.
   - **A review link leaked** (an editor's): the editor revokes it in Pluck (Deliver > the link > Revoke); the
     host refuses the key at once.
   - **Edit Anywhere pairing abused**: on the office Mac, remove the device in Edit Anywhere; close pairing.
   - **Bad app release / compromised GitHub or signing certificate**: delete or mark the GitHub release as
     pre-release so updaters stop picking it, rotate GitHub tokens, revoke the certificate (backup and notes:
     the signing-certificate memory), publish a fixed build.
3. Keep evidence: export the relevant Cloudflare logs (they expire after 3 to 7 days), screenshots, the report
   you got. Don't delete state you may need to understand what happened, unless deleting it stops the harm.

### Hour 4 to 48: understand it

4. Answer, in the log: what data, about whom (roughly how many people, which countries), since when, who could
   have seen it, is it still exposed, what could happen to people (phishing, someone viewing a client's
   unreleased video, location from an IP address…).
5. Decide the risk:
   - **Unlikely to harm anyone** (e.g. hashed room secrets, random peer ids, IP logs seen only by Cloudflare):
     record it, no notification needed (art. 33(1)).
   - **Risk to people** (e.g. IP addresses tied to names leaked publicly, donor emails exposed): notify the
     authority within 72 h.
   - **High risk** (e.g. many people's emails plus names, or review content exposed): also tell the people
     affected, without undue delay (art. 34).

### Hour 48 to 72: tell who needs to know

6. **Belgian Data Protection Authority** (Gegevensbeschermingsautoriteit / APD): online form on
   dataprotectionauthority.be (data breach notification). If facts are missing, notify anyway with what you
   know and add the rest later (art. 33(4)).
7. **People affected** (if high risk): email if I have addresses (donors, people who wrote to me), otherwise a
   notice on pluck.tools and in the app's release notes / update prompt.
8. **Editors** whose clients may be affected: notice in the app and on the site, with the facts they need for
   their own notification.
9. **Cloudflare** if the cause is on their side (abuse/security contact in the dashboard).
10. **CRA (only if it applies, see the main legal doc)**: from 11 September 2026 an *actively exploited*
    vulnerability in a product under the CRA must be reported through ENISA's single reporting platform:
    early warning within 24 h, notification within 72 h, final report within 14 days of a fix (CRA art. 14).
    If unsure whether Pluck is under the CRA, ask the lawyer once, in advance, not during an incident.

### After

11. Fix the cause, add a regression test, note the fix in the release notes.
12. Close the log: what happened, what was done, what changes so it doesn't happen again.

## Templates

### To the Data Protection Authority (fields the form asks; keep answers factual)

- Controller: [PUBLISHER NAME], [ADDRESS], [CONTACT EMAIL]
- When it happened / when I found out: …
- What happened: … (e.g. "a bug in the signaling server stored connection details, including IP addresses, of
  review page visitors for N days instead of not storing them")
- Data and people: categories (IP addresses / names / email addresses), about N people, countries if known
- Likely consequences: …
- What I did: contained on … (how), data deleted on …, fix released on …
- Whether people were told: yes/no, how, or why not
- Contact for questions: [CONTACT EMAIL]

### To people affected

> Subject: A security problem in Pluck that affects your data
>
> On [date] I found that [what happened, in one or two plain sentences]. It affected [what data: e.g. your
> email address and the name you gave when you donated]. It did not affect [what was safe: e.g. any videos,
> files or passwords].
>
> I fixed it on [date] by [what]. [What you can do: e.g. be careful with emails that claim to come from Pluck
> and ask for money or a password. Pluck never asks for either.]
>
> I'm sorry. If you have questions, reply to this email or write to [CONTACT EMAIL]. You can also contact the
> Belgian Data Protection Authority (dataprotectionauthority.be).
>
> [PUBLISHER NAME]

### To editors (release notes / site notice)

> **Security notice for Pluck Review ([date])**
> [What happened.] [Which links or versions: e.g. links shared between X and Y.] Your files stayed on your Mac.
> What to do: update to [version]; revoke and reshare links created before [date] if [condition]. If your
> clients' personal data may be affected, you may need to inform them or your data protection authority as
> their controller; the facts are above. Questions: [CONTACT EMAIL].
