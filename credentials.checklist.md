# Credentials Checklist (Phase 0)

> **Purpose:** Every external account, API key, and credential the system needs.
> **Rule:** Do NOT start Phase 3+ until every box below is checked.
> **Storage:** All values go into `.env` on the Oracle VM. Never commit `.env`.

---

## 1. Hosting & Infra

### [ ] Oracle Cloud (Always Free)
- Sign up: https://www.oracle.com/cloud/free/
- Create: 1× **VM.Standard.A1.Flex** (ARM, 4 OCPU, 24 GB RAM)
- Region: pick closest to your target client base (e.g., `us-east-1`, `eu-frankfurt-1`, `ap-mumbai-1`)
- OS: Ubuntu 22.04 LTS
- Capture: public IP, SSH key, instance OCID
- **WARNING:** Oracle reclaims idle free instances. Run a CPU heartbeat (handled by n8n in Phase 8).

**Env vars to record:**
```
ORACLE_VM_IP=
ORACLE_VM_USER=ubuntu
ORACLE_SSH_KEY_PATH=~/.ssh/oracle_ai_medical.pem
```

### [ ] Cloudflare
- Sign up: https://dash.cloudflare.com/sign-up
- Add a domain (own one, or use a free subdomain provider for POC)
- Create a **Cloudflare Tunnel** for the Oracle VM
- Note the tunnel token

**Env vars to record:**
```
CLOUDFLARE_TUNNEL_TOKEN=
CLOUDFLARE_DOMAIN=
N8N_PUBLIC_URL=https://n8n.<yourdomain>
```

### [ ] Domain (for sender authentication)
- Required for SPF/DKIM/DMARC on the Brevo sender (Phase 7)
- Even POC needs this — Gmail throttles unknown senders heavily

---

## 2. Database

### [ ] Supabase (Free)
- Sign up: https://supabase.com
- Create new project: name it `ai-medical-prod`
- Region: same as Oracle VM region
- Save: project URL, anon key, **service_role key** (server-only), DB password
- Enable: PostgreSQL extensions `uuid-ossp`, `pgcrypto`

**Env vars to record:**
```
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_DB_PASSWORD=
SUPABASE_DB_URL=postgresql://postgres:<pwd>@db.<ref>.supabase.co:5432/postgres
```

> **Note:** Supabase pauses free projects after 7 days of zero activity. WF-4 includes a heartbeat ping every 6 hours.

---

## 3. WhatsApp (Meta Cloud API)

### [ ] Meta for Developers
- Sign up: https://developers.facebook.com/
- Create App → Type: **Business**
- Add product: **WhatsApp**
- During Phase 0/1, use the **test phone number** Meta provides (free, 5 recipients allowed)
- For real launch (Phase 12): submit Business Verification, attach a **fresh phone number never used on WhatsApp before**

**Env vars to record:**
```
META_APP_ID=
META_APP_SECRET=
META_WHATSAPP_PHONE_NUMBER_ID=
META_WHATSAPP_BUSINESS_ACCOUNT_ID=
META_WHATSAPP_ACCESS_TOKEN=
META_WHATSAPP_VERIFY_TOKEN=<random_string_you_make_up>
```

> **Reality check:** Meta Business Verification takes 1–2 weeks and may reject if your business has no website. Build a simple landing page on Cloudflare Pages first.

---

## 4. AI Providers (failover chain)

### [ ] Groq (Primary)
- Sign up: https://console.groq.com
- Create API key
- Free tier: 14,400 requests/day, ~30 RPM on `llama-3.3-70b-versatile`

**Env vars to record:**
```
GROQ_API_KEY=
GROQ_MODEL=llama-3.3-70b-versatile
GROQ_DAILY_LIMIT=14000
```

### [ ] Google AI Studio — Gemini 2.0 Flash (Fallback #1)
- Sign up: https://aistudio.google.com/
- Create API key
- Free tier: 1,500 requests/day, 15 RPM

**Env vars to record:**
```
GEMINI_API_KEY=
GEMINI_MODEL=gemini-2.0-flash-exp
GEMINI_DAILY_LIMIT=1400
```

### [ ] OpenRouter (Fallback #2 / last resort)
- Sign up: https://openrouter.ai
- Create API key
- Use only models tagged `:free` (changes monthly — verify before use)

**Env vars to record:**
```
OPENROUTER_API_KEY=
OPENROUTER_MODEL=meta-llama/llama-3.3-70b-instruct:free
```

---

## 5. Email Providers (4-slot rotation + audit)

> **Strategy notes (already discussed):**
> - **Self-test phase (Phase 10):** Gmail#1 → Gmail#2 → Gmail#3 → Brevo
> - **Real client phase (Phase 12+):** flip order to Brevo → Gmail#1 → Gmail#2 → Gmail#3
> - Order is configured in `architecture.json::providers.email.rotation_order` — single config flip, no code change.

### [ ] Gmail Account #1
- Use a real Gmail (or Google Workspace) account
- Enable 2FA, then create an **App Password** (not OAuth — simpler for SMTP in n8n)
- App Password: Google Account → Security → 2-Step Verification → App passwords
- Daily SMTP limit: 500 sends/day

**Env vars:**
```
GMAIL_1_USER=youraccount1@gmail.com
GMAIL_1_APP_PASSWORD=<16-char app password>
```

### [ ] Gmail Account #2
Same as above with different account.
```
GMAIL_2_USER=
GMAIL_2_APP_PASSWORD=
```

### [ ] Gmail Account #3
```
GMAIL_3_USER=
GMAIL_3_APP_PASSWORD=
```

### [ ] Brevo (Sendinblue)
- Sign up: https://www.brevo.com/
- Free tier: 300 emails/day forever
- Verify a sender domain (NOT just an email — domain auth is required for deliverability)
- Set up SPF, DKIM, DMARC records in Cloudflare DNS

**Env vars:**
```
BREVO_API_KEY=
BREVO_SENDER_EMAIL=bookings@<yourdomain>
BREVO_SENDER_NAME=AI Medical Bookings
```

> **Reality check:** All 4 senders must use the SAME `From Name` and a verified domain in their `Reply-To`, or rotation will get spam-filtered.

---

## 6. Monitoring & Ops (free tier)

### [ ] Sentry (Free)
- Sign up: https://sentry.io
- Free tier: 5k errors/month
- Create project: `ai-medical-n8n`
- Capture DSN

**Env vars:**
```
SENTRY_DSN=
```

### [ ] Better Stack — Logs + Uptime (Free)
- Sign up: https://betterstack.com
- Free tier: 1GB logs/mo, 10 monitors
- Create source: `n8n-oracle-vm`
- Create uptime monitor: HTTPS check on `N8N_PUBLIC_URL/healthz`

**Env vars:**
```
BETTERSTACK_LOGS_TOKEN=
BETTERSTACK_UPTIME_HEARTBEAT_URL=
```

### [ ] Telegram Bot (admin alerts to YOU, not patients)
- Open Telegram → message `@BotFather` → `/newbot`
- Save bot token
- Get your own user chat ID by messaging `@userinfobot`

**Env vars:**
```
TELEGRAM_ADMIN_BOT_TOKEN=
TELEGRAM_ADMIN_CHAT_ID=
```

---

## 7. GitHub

### [ ] Repo: `vallakatlaraviteja/AI_medical`
- Already created ✅
- Add a deploy key or PAT for CI/CD if you wire that later

---

## Final pre-flight check

Before moving to Phase 3 (infra setup), confirm:

- [ ] Every env var above has a real value (no blanks, no placeholders)
- [ ] `.env` file built locally — **never committed**
- [ ] `.env.example` committed (will be created in Phase 3) with empty values + comments
- [ ] You can SSH into the Oracle VM
- [ ] You can connect to Supabase from your laptop using the connection string
- [ ] Meta WhatsApp test number can send/receive a "hello" via curl to the Cloud API
- [ ] Each Gmail App Password works in a quick `swaks` SMTP test
- [ ] Brevo API key works in a quick curl POST to `/v3/smtp/email`

When all 8 items above are GREEN, you're ready for Phase 3.
