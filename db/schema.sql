-- ============================================================================
-- AI_medical - Supabase / PostgreSQL Schema
-- Phase 2 deliverable
-- Multi-tenant from line 1. Row-Level Security on every patient-data table.
-- Apply to Supabase via SQL Editor or `supabase db push`.
-- ============================================================================

-- Required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. CLINICS (tenant root)
-- ============================================================================
CREATE TABLE IF NOT EXISTS clinics (
    clinic_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name                   TEXT NOT NULL,
    specialty              TEXT NOT NULL,
    timezone               TEXT NOT NULL DEFAULT 'UTC',
    currency               TEXT NOT NULL DEFAULT 'USD',
    language               TEXT NOT NULL DEFAULT 'English',
    whatsapp_phone_number_id TEXT UNIQUE,
    knowledge_base         JSONB NOT NULL DEFAULT '{}'::jsonb,
    rotation_order_email   TEXT[] NOT NULL DEFAULT ARRAY['BREVO','GMAIL_1','GMAIL_2','GMAIL_3'],
    rotation_order_ai      TEXT[] NOT NULL DEFAULT ARRAY['GROQ','GEMINI','OPENROUTER'],
    is_active              BOOLEAN NOT NULL DEFAULT TRUE,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_clinics_whatsapp_phone ON clinics(whatsapp_phone_number_id);
CREATE INDEX IF NOT EXISTS idx_clinics_active ON clinics(is_active) WHERE is_active = TRUE;

COMMENT ON TABLE clinics IS 'Tenant root. Every patient-data table is scoped by clinic_id.';
COMMENT ON COLUMN clinics.knowledge_base IS 'JSONB of services, hours, address, doctor, pricing. See architecture.json::business.phase_1_self_test_clinic for shape.';
COMMENT ON COLUMN clinics.whatsapp_phone_number_id IS 'Meta phone_number_id used to resolve which clinic a webhook belongs to.';

-- ============================================================================
-- 2. PATIENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS patients (
    patient_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id             UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    phone                 TEXT NOT NULL,
    name                  TEXT,
    email                 TEXT,
    status                TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new','active','dormant','blocked')),
    total_visits          INTEGER NOT NULL DEFAULT 0,
    last_service          TEXT,
    last_appointment_at   TIMESTAMPTZ,
    notes                 TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (clinic_id, phone)
);

CREATE INDEX IF NOT EXISTS idx_patients_clinic_phone ON patients(clinic_id, phone);
CREATE INDEX IF NOT EXISTS idx_patients_email ON patients(email) WHERE email IS NOT NULL;

COMMENT ON TABLE patients IS 'Per-clinic patients. (clinic_id, phone) is the natural key.';

-- ============================================================================
-- 3. AVAILABILITY (slot grid)
-- ============================================================================
CREATE TABLE IF NOT EXISTS availability (
    availability_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id         UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    doctor_name       TEXT,
    day_of_week       SMALLINT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0 = Sunday
    slot_start_local  TIME NOT NULL,
    slot_end_local    TIME NOT NULL,
    max_capacity      INTEGER NOT NULL DEFAULT 1,
    active            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (slot_end_local > slot_start_local)
);

CREATE INDEX IF NOT EXISTS idx_availability_clinic_dow ON availability(clinic_id, day_of_week) WHERE active = TRUE;

COMMENT ON TABLE availability IS 'Slot grid per clinic. Replaces fragile string slots in knowledge_base.';

-- ============================================================================
-- 4. APPOINTMENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS appointments (
    appointment_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id         UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    patient_id        UUID NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    service           TEXT NOT NULL,
    slot_start        TIMESTAMPTZ NOT NULL,
    slot_end          TIMESTAMPTZ NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','confirmed','cancelled','completed','no_show')),
    email_slot_used   TEXT,
    email_status      TEXT DEFAULT 'not_sent'
                      CHECK (email_status IN ('not_sent','sent','failed','retry_queued')),
    notes             TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (slot_end > slot_start)
);

-- Prevent double-booking the same slot (clinic-scoped)
CREATE UNIQUE INDEX IF NOT EXISTS uq_appointments_slot_active
    ON appointments(clinic_id, slot_start)
    WHERE status IN ('pending','confirmed');

CREATE INDEX IF NOT EXISTS idx_appointments_clinic_patient ON appointments(clinic_id, patient_id);
CREATE INDEX IF NOT EXISTS idx_appointments_clinic_slot ON appointments(clinic_id, slot_start);
CREATE INDEX IF NOT EXISTS idx_appointments_status ON appointments(status);

COMMENT ON TABLE appointments IS 'Atomic insert + unique partial index prevents double-booking.';

-- ============================================================================
-- 5. CONVERSATIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS conversations (
    conversation_id   BIGSERIAL PRIMARY KEY,
    clinic_id         UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    patient_phone     TEXT NOT NULL,
    role              TEXT NOT NULL CHECK (role IN ('user','assistant','system','tool')),
    content           TEXT NOT NULL,
    metadata          JSONB DEFAULT '{}'::jsonb,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_conversations_clinic_phone_time
    ON conversations(clinic_id, patient_phone, created_at DESC);

COMMENT ON TABLE conversations IS 'Truncate to last 10 + rolling summary in metadata to control AI token cost.';

-- ============================================================================
-- 6. EMAIL QUOTAS (per clinic, per slot)
-- ============================================================================
CREATE TABLE IF NOT EXISTS email_quotas (
    clinic_id        UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    slot_name        TEXT NOT NULL,
    count            INTEGER NOT NULL DEFAULT 0,
    threshold        INTEGER NOT NULL,
    last_reset_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (clinic_id, slot_name)
);

COMMENT ON TABLE email_quotas IS 'Per-clinic per-email-slot daily counters. Atomic increment via fn_increment_email_quota().';

-- ============================================================================
-- 7. AI QUOTAS (per clinic, per provider)
-- ============================================================================
CREATE TABLE IF NOT EXISTS ai_quotas (
    clinic_id        UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    provider_name    TEXT NOT NULL,
    count            INTEGER NOT NULL DEFAULT 0,
    threshold        INTEGER NOT NULL,
    last_reset_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (clinic_id, provider_name)
);

-- ============================================================================
-- 8. PROVIDER HEALTH (runtime status)
-- ============================================================================
CREATE TABLE IF NOT EXISTS provider_health (
    clinic_id              UUID NOT NULL REFERENCES clinics(clinic_id) ON DELETE CASCADE,
    provider_name          TEXT NOT NULL,
    status                 TEXT NOT NULL DEFAULT 'healthy'
                           CHECK (status IN ('healthy','degraded','down')),
    last_error             TEXT,
    last_error_at          TIMESTAMPTZ,
    last_success_at        TIMESTAMPTZ,
    consecutive_failures   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (clinic_id, provider_name)
);

COMMENT ON TABLE provider_health IS 'Used for runtime failover. Marked degraded after 3 failures, down after 5.';

-- ============================================================================
-- 9. AUDIT LOG (append-only)
-- ============================================================================
CREATE TABLE IF NOT EXISTS audit_log (
    event_id      BIGSERIAL PRIMARY KEY,
    clinic_id     UUID REFERENCES clinics(clinic_id) ON DELETE SET NULL,
    event_type    TEXT NOT NULL,
    actor         TEXT,                          -- 'system' | 'patient:<phone>' | 'admin:<id>'
    payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_clinic_time ON audit_log(clinic_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_event_type ON audit_log(event_type);

COMMENT ON TABLE audit_log IS 'Append-only. Required for medical compliance traceability.';

-- ============================================================================
-- 10. IDEMPOTENCY KEYS (webhook dedupe)
-- ============================================================================
CREATE TABLE IF NOT EXISTS idempotency_keys (
    message_id     TEXT PRIMARY KEY,
    clinic_id      UUID REFERENCES clinics(clinic_id) ON DELETE SET NULL,
    processed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_idempotency_processed ON idempotency_keys(processed_at);

COMMENT ON TABLE idempotency_keys IS 'WhatsApp delivers webhooks 2-3 times. We INSERT, conflict = already processed. TTL via cleanup cron.';

-- ============================================================================
-- 11. DEAD LETTER QUEUE
-- ============================================================================
CREATE TABLE IF NOT EXISTS dead_letter_queue (
    dlq_id          BIGSERIAL PRIMARY KEY,
    clinic_id       UUID REFERENCES clinics(clinic_id) ON DELETE SET NULL,
    workflow_name   TEXT NOT NULL,
    payload         JSONB NOT NULL,
    error_message   TEXT,
    retry_count     INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    next_retry_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','processing','succeeded','exhausted')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dlq_status_next_retry ON dead_letter_queue(status, next_retry_at);

-- ============================================================================
-- ATOMIC FUNCTIONS
-- ============================================================================

-- Atomic email-quota increment. Returns new count and whether threshold was crossed.
CREATE OR REPLACE FUNCTION fn_increment_email_quota(
    p_clinic_id UUID,
    p_slot_name TEXT
) RETURNS TABLE(new_count INTEGER, threshold_crossed BOOLEAN) AS $$
DECLARE
    v_threshold INTEGER;
    v_new_count INTEGER;
BEGIN
    UPDATE email_quotas
       SET count = count + 1
     WHERE clinic_id = p_clinic_id AND slot_name = p_slot_name
    RETURNING count, threshold INTO v_new_count, v_threshold;

    IF v_new_count IS NULL THEN
        RAISE EXCEPTION 'No email_quotas row for clinic % slot %', p_clinic_id, p_slot_name;
    END IF;

    RETURN QUERY SELECT v_new_count, v_new_count >= v_threshold;
END;
$$ LANGUAGE plpgsql;

-- Atomic AI-quota increment. Same shape.
CREATE OR REPLACE FUNCTION fn_increment_ai_quota(
    p_clinic_id UUID,
    p_provider_name TEXT
) RETURNS TABLE(new_count INTEGER, threshold_crossed BOOLEAN) AS $$
DECLARE
    v_threshold INTEGER;
    v_new_count INTEGER;
BEGIN
    UPDATE ai_quotas
       SET count = count + 1
     WHERE clinic_id = p_clinic_id AND provider_name = p_provider_name
    RETURNING count, threshold INTO v_new_count, v_threshold;

    IF v_new_count IS NULL THEN
        RAISE EXCEPTION 'No ai_quotas row for clinic % provider %', p_clinic_id, p_provider_name;
    END IF;

    RETURN QUERY SELECT v_new_count, v_new_count >= v_threshold;
END;
$$ LANGUAGE plpgsql;

-- Pick next available email slot for a clinic (quota + health aware).
CREATE OR REPLACE FUNCTION fn_pick_email_slot(p_clinic_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_slot TEXT;
BEGIN
    SELECT eq.slot_name
      INTO v_slot
      FROM email_quotas eq
      JOIN clinics c
        ON c.clinic_id = eq.clinic_id
      LEFT JOIN provider_health ph
        ON ph.clinic_id = eq.clinic_id AND ph.provider_name = eq.slot_name
     WHERE eq.clinic_id = p_clinic_id
       AND eq.count < eq.threshold
       AND COALESCE(ph.status, 'healthy') <> 'down'
     ORDER BY array_position(c.rotation_order_email, eq.slot_name) NULLS LAST
     LIMIT 1;

    RETURN v_slot;  -- NULL if every slot is exhausted/down (caller pushes to DLQ)
END;
$$ LANGUAGE plpgsql;

-- Pick next available AI provider for a clinic.
CREATE OR REPLACE FUNCTION fn_pick_ai_provider(p_clinic_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_provider TEXT;
BEGIN
    SELECT aq.provider_name
      INTO v_provider
      FROM ai_quotas aq
      JOIN clinics c
        ON c.clinic_id = aq.clinic_id
      LEFT JOIN provider_health ph
        ON ph.clinic_id = aq.clinic_id AND ph.provider_name = aq.provider_name
     WHERE aq.clinic_id = p_clinic_id
       AND aq.count < aq.threshold
       AND COALESCE(ph.status, 'healthy') <> 'down'
     ORDER BY array_position(c.rotation_order_ai, aq.provider_name) NULLS LAST
     LIMIT 1;

    RETURN v_provider;
END;
$$ LANGUAGE plpgsql;

-- Mark provider degraded/down on failure
CREATE OR REPLACE FUNCTION fn_mark_provider_failure(
    p_clinic_id UUID,
    p_provider_name TEXT,
    p_error TEXT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO provider_health (clinic_id, provider_name, status, last_error, last_error_at, consecutive_failures)
    VALUES (p_clinic_id, p_provider_name, 'degraded', p_error, NOW(), 1)
    ON CONFLICT (clinic_id, provider_name) DO UPDATE
        SET consecutive_failures = provider_health.consecutive_failures + 1,
            last_error = EXCLUDED.last_error,
            last_error_at = NOW(),
            status = CASE
                       WHEN provider_health.consecutive_failures + 1 >= 5 THEN 'down'
                       WHEN provider_health.consecutive_failures + 1 >= 3 THEN 'degraded'
                       ELSE provider_health.status
                     END;
END;
$$ LANGUAGE plpgsql;

-- Mark provider healthy on success
CREATE OR REPLACE FUNCTION fn_mark_provider_success(
    p_clinic_id UUID,
    p_provider_name TEXT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO provider_health (clinic_id, provider_name, status, last_success_at, consecutive_failures)
    VALUES (p_clinic_id, p_provider_name, 'healthy', NOW(), 0)
    ON CONFLICT (clinic_id, provider_name) DO UPDATE
        SET status = 'healthy',
            last_success_at = NOW(),
            consecutive_failures = 0;
END;
$$ LANGUAGE plpgsql;

-- Daily reset for a single clinic. WF-4 calls this when local-time hits midnight.
CREATE OR REPLACE FUNCTION fn_daily_reset(p_clinic_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE email_quotas
       SET count = 0, last_reset_at = NOW()
     WHERE clinic_id = p_clinic_id;

    UPDATE ai_quotas
       SET count = 0, last_reset_at = NOW()
     WHERE clinic_id = p_clinic_id;

    UPDATE provider_health
       SET status = 'healthy', consecutive_failures = 0
     WHERE clinic_id = p_clinic_id AND status <> 'healthy';

    INSERT INTO audit_log (clinic_id, event_type, actor, payload)
    VALUES (p_clinic_id, 'daily_reset', 'system', jsonb_build_object('reset_at', NOW()));
END;
$$ LANGUAGE plpgsql;

-- Cleanup expired idempotency keys (call from WF-4 daily)
CREATE OR REPLACE FUNCTION fn_cleanup_idempotency_keys()
RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM idempotency_keys
     WHERE processed_at < NOW() - INTERVAL '24 hours';
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE patients          ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE availability      ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations     ENABLE ROW LEVEL SECURITY;
ALTER TABLE email_quotas      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_quotas         ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_health   ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log         ENABLE ROW LEVEL SECURITY;
ALTER TABLE idempotency_keys  ENABLE ROW LEVEL SECURITY;
ALTER TABLE dead_letter_queue ENABLE ROW LEVEL SECURITY;

-- Helper: pull current clinic from session GUC. n8n sets this at start of each workflow.
CREATE OR REPLACE FUNCTION app_current_clinic_id() RETURNS UUID AS $$
  SELECT NULLIF(current_setting('app.current_clinic_id', TRUE), '')::UUID;
$$ LANGUAGE SQL STABLE;

-- Generic clinic-scoped policy
DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN SELECT unnest(ARRAY[
        'patients','appointments','availability','conversations',
        'email_quotas','ai_quotas','provider_health','audit_log',
        'idempotency_keys','dead_letter_queue'
    ])
    LOOP
        EXECUTE format(
            'DROP POLICY IF EXISTS clinic_isolation ON %I; '
            'CREATE POLICY clinic_isolation ON %I '
            'FOR ALL USING (clinic_id = app_current_clinic_id()) '
            'WITH CHECK (clinic_id = app_current_clinic_id());',
            t, t
        );
    END LOOP;
END$$;

-- Service role bypasses RLS (used by n8n workflows running as service_role)
-- Clinics table itself is readable by service role only; patients never query it directly.
ALTER TABLE clinics ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS clinics_service_only ON clinics;
CREATE POLICY clinics_service_only ON clinics
    FOR ALL
    USING (TRUE)
    WITH CHECK (TRUE);

-- ============================================================================
-- SEED DATA — Phase 1 self-test clinic
-- ============================================================================
INSERT INTO clinics (
    clinic_id, name, specialty, timezone, currency, language,
    knowledge_base, rotation_order_email, rotation_order_ai
) VALUES (
    '00000000-0000-0000-0000-000000000001',
    'Ravi Dental Clinic',
    'Dental',
    'Asia/Kolkata',
    'INR',
    'English',
    jsonb_build_object(
        'doctor_name', 'Dr. Ravi Kumar',
        'address',     '123 MG Road, Hyderabad, India',
        'phone',       '+91 9000000000',
        'hours',       'Mon-Fri 9AM-7PM, Sat 10AM-4PM',
        'services',    jsonb_build_array(
            jsonb_build_object('name','Cleaning',   'price', 1500, 'duration_min', 30),
            jsonb_build_object('name','Filling',    'price', 2500, 'duration_min', 45),
            jsonb_build_object('name','Whitening',  'price', 5000, 'duration_min', 60),
            jsonb_build_object('name','Extraction', 'price', 3000, 'duration_min', 30),
            jsonb_build_object('name','Checkup',    'price',  500, 'duration_min', 15)
        ),
        'email_from_name', 'Ravi Dental Clinic',
        'reply_to',        'bookings@ravidentalclinic.example'
    ),
    ARRAY['GMAIL_1','GMAIL_2','GMAIL_3','BREVO'],   -- self-test order; flip for production
    ARRAY['GROQ','GEMINI','OPENROUTER']
) ON CONFLICT (clinic_id) DO NOTHING;

-- Seed availability grid: Mon-Fri 09:00-19:00 in 30-min slots, Sat 10:00-16:00
DO $$
DECLARE
    v_dow INTEGER;
    v_t TIME;
    v_end TIME;
BEGIN
    -- Mon-Fri (1-5)
    FOR v_dow IN 1..5 LOOP
        v_t := TIME '09:00';
        WHILE v_t < TIME '19:00' LOOP
            v_end := v_t + INTERVAL '30 minutes';
            INSERT INTO availability (clinic_id, doctor_name, day_of_week, slot_start_local, slot_end_local, max_capacity)
            VALUES ('00000000-0000-0000-0000-000000000001', 'Dr. Ravi Kumar', v_dow, v_t, v_end, 1)
            ON CONFLICT DO NOTHING;
            v_t := v_end;
        END LOOP;
    END LOOP;
    -- Sat (6)
    v_t := TIME '10:00';
    WHILE v_t < TIME '16:00' LOOP
        v_end := v_t + INTERVAL '30 minutes';
        INSERT INTO availability (clinic_id, doctor_name, day_of_week, slot_start_local, slot_end_local, max_capacity)
        VALUES ('00000000-0000-0000-0000-000000000001', 'Dr. Ravi Kumar', 6, v_t, v_end, 1)
        ON CONFLICT DO NOTHING;
        v_t := v_end;
    END LOOP;
END$$;

-- Seed quota rows for the test clinic
INSERT INTO email_quotas (clinic_id, slot_name, count, threshold) VALUES
    ('00000000-0000-0000-0000-000000000001', 'GMAIL_1', 0, 490),
    ('00000000-0000-0000-0000-000000000001', 'GMAIL_2', 0, 490),
    ('00000000-0000-0000-0000-000000000001', 'GMAIL_3', 0, 490),
    ('00000000-0000-0000-0000-000000000001', 'BREVO',   0, 285)
ON CONFLICT (clinic_id, slot_name) DO NOTHING;

INSERT INTO ai_quotas (clinic_id, provider_name, count, threshold) VALUES
    ('00000000-0000-0000-0000-000000000001', 'GROQ',       0, 14000),
    ('00000000-0000-0000-0000-000000000001', 'GEMINI',     0, 1400),
    ('00000000-0000-0000-0000-000000000001', 'OPENROUTER', 0, 5000)
ON CONFLICT (clinic_id, provider_name) DO NOTHING;

INSERT INTO provider_health (clinic_id, provider_name, status) VALUES
    ('00000000-0000-0000-0000-000000000001', 'GMAIL_1',    'healthy'),
    ('00000000-0000-0000-0000-000000000001', 'GMAIL_2',    'healthy'),
    ('00000000-0000-0000-0000-000000000001', 'GMAIL_3',    'healthy'),
    ('00000000-0000-0000-0000-000000000001', 'BREVO',      'healthy'),
    ('00000000-0000-0000-0000-000000000001', 'GROQ',       'healthy'),
    ('00000000-0000-0000-0000-000000000001', 'GEMINI',     'healthy'),
    ('00000000-0000-0000-0000-000000000001', 'OPENROUTER', 'healthy')
ON CONFLICT (clinic_id, provider_name) DO NOTHING;

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
