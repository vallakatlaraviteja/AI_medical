# Stack Decisions — Why Each Tool Was Picked

> Every choice below was made against three constraints: **truly free for POC**, **production-credible for foreign clients**, **survives quota exhaustion automatically**.

---

## Hosting → Oracle Cloud Always Free (ARM)

**Picked because:**
- Genuinely free forever (not a 12-month trial)
- 4 OCPU ARM + 24 GB RAM is real compute, not a toy
- Public IP included, ports configurable

**Risks accepted:**
- Oracle reclaims "idle" instances → mitigated by WF-4 heartbeat
- ARM architecture means we pin Docker images that have ARM variants (n8n does)

**Rejected:**
- Heroku free tier (killed in 2022)
- Render free (sleeps after 15 min)
- Fly.io free (now requires payment method)
- Railway free (heavily limited, exhausts in days)

---

## Database → Supabase

**Picked because:**
- Real PostgreSQL — supports row locks, atomic functions, JSONB, RLS
- 500 MB DB + 2 GB egress + 50k MAU is plenty for one clinic
- Built-in REST + GraphQL if we ever expose APIs to clients

**Risks accepted:**
- Free project pauses after 7 idle days → mitigated by WF-4 6-hour heartbeat
- Free tier doesn't have automated daily backups → we run a manual `pg_dump` to Cloudflare R2 weekly

**Rejected:**
- Google Sheets — race conditions on concurrent bookings, not transactional, audit-hostile
- Firebase free — NoSQL is wrong shape for relational appointment data
- Neon free — good but smaller free tier than Supabase
- PlanetScale free — killed in 2024

---

## Automation Engine → Self-hosted n8n

**Picked because:**
- Open-source, runs anywhere
- Visual workflow editor (you, your interns, future hires can read it)
- 400+ pre-built integrations (WhatsApp, Gmail, Brevo, Groq via HTTP, Supabase native node)
- Native Error Trigger + Webhook nodes are exactly what we need

**Risks accepted:**
- We maintain it (updates, backups) → run on pinned version, weekly snapshots
- Free self-hosted edition is the **community** edition; lacks enterprise SSO etc. (we don't need those)

**Rejected:**
- n8n Cloud ($20/mo) — fine but not free
- Make.com / Zapier — paid, expensive at our intended volume
- Custom Node.js orchestrator — much more work, harder to support clients later

---

## Public HTTPS → Cloudflare Tunnel

**Picked because:**
- Free, no port-forwarding (Oracle's free tier defaults firewall to closed)
- Auto SSL, no Let's Encrypt setup
- Hides VM IP from public internet (security win)

**Rejected:**
- ngrok free — random URLs, daily session limits
- Tailscale Funnel — quotas, not designed for prod
- Self-managed nginx + certbot — extra ops

---

## WhatsApp Channel → Meta Cloud API

**Picked because:**
- The only WhatsApp option for businesses (Twilio/360dialog wrap the same API at higher prices)
- 1000 service conversations/month genuinely free — enough for POC and small clinics
- Templates + interactive messages supported

**Risks accepted:**
- 1-2 week Business Verification → start NOW, run other phases in parallel
- Need fresh phone number → buy a SIM, $5-10 one-time
- Per-conversation cost after free tier → **client pays Meta directly**, billed via their own credit card; we never touch their money for WhatsApp

**For internal smoke-test only:** Telegram Bot. Free, instant, no verification. Used in Phase 4 dev only — never delivered to clients as the channel.

---

## AI Layer → Groq → Gemini → OpenRouter

**Why three providers, not one:**
Free tier rate limits are tight. A clinic at peak hours (Monday 9am) might hit Groq's RPM limit in seconds. Without runtime failover, the bot looks broken and clients churn.

| Provider | Why this slot |
|---|---|
| **Groq (primary)** | Llama-3.3-70b is excellent for booking conversations. Free tier 14,400/day. Fastest inference of any free LLM right now. |
| **Gemini 2.0 Flash (fallback #1)** | Different vendor = different rate-limit pool. 1,500/day on top of Groq's. |
| **OpenRouter (fallback #2)** | Last-resort. Lots of free models. Slower, sometimes flaky, but unlikely all three are down at once. |

**Risks accepted:**
- Groq is a startup — free tier could change → already designed for failover
- OpenRouter free models change name/availability monthly → architecture.json::ai.OPENROUTER.warning notes this; review before each deployment

**Rejected:**
- OpenAI — no free tier (GPT-4o-mini is paid only)
- Claude — no free API tier
- Local Llama on Oracle VM — 4 OCPU ARM is too weak for 70B models; would need a tiny 7B model that's worse for this use case

---

## Email Layer → 3× Gmail SMTP + Brevo (rotating)

**Why this stack (and what changes for production):**

For self-test (Phase 1-10):
- Gmail#1 → Gmail#2 → Gmail#3 → Brevo
- Gmail dominant because we have 3 accounts, total ~1500/day capacity
- Brevo is the safety net

For production / paying clients (Phase 12+):
- **Brevo → Gmail#1 → Gmail#2 → Gmail#3** (flip via env var, no code change)
- Why flip? Gmail throttles "new sender" reputation hard for transactional bursts. Brevo is purpose-built for transactional, has DKIM/SPF/DMARC done right, far better inbox placement.
- Gmail rotation stays as backup — only used if Brevo is down or quota hit.

**Risks accepted:**
- Gmail App Passwords being phased out → if forced, we switch to OAuth2 in n8n's Gmail node (still free, just more setup)
- Multi-account Gmail rotation is operationally fragile → Brevo-primary in production largely sidesteps this

**Rejected:**
- SES (Amazon) — requires production access approval, not "free forever"
- Mailgun free — discontinued in 2024
- Resend free 3k/mo — solid alternative; can add as 5th slot in v2 if needed
- SendGrid free 100/day — too small to matter

---

## DNS + Sender Auth → Cloudflare DNS

**Picked because:**
- Free DNS, instant propagation
- Easy SPF/DKIM/DMARC record entry
- Same dashboard as Cloudflare Tunnel

**Mandatory:** every email-sending domain MUST have SPF + DKIM + DMARC. Without them, Brevo/Gmail emails land in spam → clients fire us.

---

## Monitoring → Sentry + Better Stack + Telegram

| Tool | Used for | Why free tier is enough |
|---|---|---|
| Sentry | Error tracking inside workflows | 5k events/mo > our scale |
| Better Stack | Logs + uptime ping | 1 GB logs/mo, 10 monitors |
| Telegram bot | Owner-only ops alerts | Free, instant push to your phone |

**Rejected:**
- Datadog — no real free tier
- New Relic free — limited to 1 user, expires
- Self-hosted Grafana stack — over-engineering at this stage

---

## CI/CD

Skipped intentionally for Phase 0-11. Manual deploy via `git pull && docker compose up -d` on the Oracle VM is fine for solo dev. We add GitHub Actions only when we have multiple clinics and need zero-downtime deploys.

---

## What We Do NOT Use (and why)

| Tool | Why rejected |
|---|---|
| Google Sheets as DB | Race conditions on concurrent writes |
| Airtable | Free tier rate-limited and not transactional |
| Firebase | Wrong data shape for our relational model |
| Stripe (yet) | No payments in v1 — clinic pays us via wire/PayPal/Wise |
| HubSpot CRM | Adds complexity; we use Supabase tables for CRM |
| ChatGPT API | Not free |
| Twilio WhatsApp | Wraps Meta API at higher cost |
| AWS anything | Free tiers expire after 12 months |

---

## When We Will Spend Money

**Trigger 1: First paying client.** Then immediately:
- Brevo Lite ($9/mo) — guaranteed deliverability
- Domain renewal ($12/year) — already needed in Phase 0

**Trigger 2: Three paying clients.** Then add:
- Supabase Pro ($25/mo) — daily backups, no auto-pause
- n8n Cloud ($20/mo) OR keep self-hosted with proper alerting

**Trigger 3: Ten paying clients.** Then:
- Move to dedicated Postgres (e.g., Crunchy Data $35/mo)
- HIPAA-compliant infra audit (~$2-5k one-time)
- Hire VA for Tier-1 client support

The architecture lets each upgrade happen as a config change — no rewrites.
