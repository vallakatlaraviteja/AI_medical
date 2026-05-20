# AI_medical

Multi-tenant medical appointment booking automation for international clinics.
**WhatsApp** ▸ **AI failover (Groq → Gemini → OpenRouter)** ▸ **Supabase** ▸ **n8n** ▸ **4-slot email rotation** ▸ on **Oracle Cloud free tier**.

Built free-first for POC. Scales to per-clinic paid tiers when you onboard real clients. Single config flip, no rewrite.

---

## Read in this order

1. **[`docs/00-the-plan.md`](./docs/00-the-plan.md)** — the 12-phase build plan
2. **[`architecture.json`](./architecture.json)** — single source of truth (every module, provider, table, policy)
3. **[`docs/stack-decisions.md`](./docs/stack-decisions.md)** — why each tool was picked, what was rejected
4. **[`credentials.checklist.md`](./credentials.checklist.md)** — Phase 0 to-do (every account & key you need)
5. **[`db/schema.sql`](./db/schema.sql)** — Supabase schema (Phase 2)

---

## Repository layout

```
AI_medical/
├── README.md                       you are here
├── architecture.json               source of truth — everything references this
├── credentials.checklist.md        Phase 0
├── db/
│   └── schema.sql                  Phase 2 — multi-tenant tables, RLS, atomic fns
├── docs/
│   ├── 00-the-plan.md              12-phase plan
│   └── stack-decisions.md          tool rationale
├── infra/                          Phase 3 (not yet)
├── workflows/                      Phase 4-9 (not yet)
├── tests/                          Phase 10 (not yet)
├── marketing/                      Phase 11 (not yet)
├── onboarding/                     Phase 12 (not yet)
└── .gitignore
```

---

## Status

Currently completed:
- ✅ Phase 0 — credentials checklist
- ✅ Phase 1 — master architecture blueprint
- ✅ Phase 2 — database schema + seed data for self-test clinic ("Ravi Dental")

Next:
- ⬜ Phase 3 — Oracle + n8n infrastructure
- ⬜ Phase 4 — WF-1 WhatsApp ingress
- ⬜ Phase 5–6 — WF-2 AI router + booking
- ⬜ Phase 7 — WF-3 email rotation
- ⬜ Phase 8 — WF-4 daily reset
- ⬜ Phase 9 — WF-5 error handler
- ⬜ Phase 10 — self-test (12 scenarios)
- ⬜ Phase 11 — demo asset
- ⬜ Phase 12 — client onboarding kit

---

## Two truths to internalize

1. **Self-test rotation order:** `GMAIL_1 → GMAIL_2 → GMAIL_3 → BREVO`.
   **Production rotation order:** `BREVO → GMAIL_1 → GMAIL_2 → GMAIL_3`.
   Flip via `clinics.rotation_order_email` (env or DB column). No code change.

2. **"Free forever" stops being a goal once you have a paying client.**
   At first paying client: pay $9/mo for Brevo Lite. Pass the cost through pricing. The client funds infrastructure.

---

## License

Proprietary. Not for redistribution. Built by [@vallakatlaraviteja](https://github.com/vallakatlaraviteja).
