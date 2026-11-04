    -- APIC ProtoHub — core schema
-- Design note: the hard problem is capability matching, not booking.
-- Everything below hangs off machine_capability.

-- btree_gist is required for EXCLUDE USING gist with integer/bigint keys (machine_id)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ====================================
-- CENTRES & PEOPLE
-- ====================================

CREATE TABLE IF NOT EXISTS centre (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    district        TEXT NOT NULL,
    address         TEXT NOT NULL,
    lat             NUMERIC(9,6) NOT NULL,
    lng             NUMERIC(9,6) NOT NULL,
    phone           TEXT,
    opens_at        TIME NOT NULL DEFAULT '09:00',
    closes_at       TIME NOT NULL DEFAULT '17:30',
    working_days    INT[] NOT NULL DEFAULT '{1,2,3,4,5,6}',
    is_live         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app_user (
    id              BIGSERIAL PRIMARY KEY,
    phone           TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,
    email           TEXT,
    role            TEXT NOT NULL CHECK (
        role IN ('innovator','centre_staff','centre_manager','apis_admin')
    ),
    centre_id       BIGINT REFERENCES centre(id),
    affiliation     TEXT CHECK (
        affiliation IN ('student','startup','industry','individual','institution')
    ),
    institution     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT staff_needs_centre CHECK (
        role IN ('innovator','apis_admin') OR centre_id IS NOT NULL
    )
);

-- ====================================
-- MACHINES & CAPABILITY
-- ====================================

CREATE TABLE IF NOT EXISTS process (
    code            TEXT PRIMARY KEY,
    family          TEXT NOT NULL,
    label           TEXT NOT NULL,
    layman_label    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS material (
    code            TEXT PRIMARY KEY,
    label           TEXT NOT NULL,
    class           TEXT NOT NULL CHECK (
        class IN ('thermoplastic','resin','metal','composite','wood','other')
    ),
    density_g_cm3   NUMERIC(6,3)
);

CREATE TABLE IF NOT EXISTS machine (
    id              BIGSERIAL PRIMARY KEY,
    centre_id       BIGINT NOT NULL REFERENCES centre(id),
    process_code    TEXT NOT NULL REFERENCES process(code),
    make            TEXT NOT NULL,
    model           TEXT NOT NULL,
    asset_tag       TEXT,
    status          TEXT NOT NULL DEFAULT 'available' CHECK (
        status IN ('available','in_use','maintenance','broken','retired')
    ),
    rate_per_hour   NUMERIC(10,2) NOT NULL,
    setup_fee       NUMERIC(10,2) NOT NULL DEFAULT 0,
    min_charge      NUMERIC(10,2) NOT NULL DEFAULT 0,
    student_discount_pct NUMERIC(5,2) NOT NULL DEFAULT 0,
    commissioned_on DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (centre_id, asset_tag)
);

CREATE TABLE IF NOT EXISTS machine_capability (
    machine_id      BIGINT PRIMARY KEY REFERENCES machine(id) ON DELETE CASCADE,
    max_x_mm        NUMERIC(8,2) NOT NULL,
    max_y_mm        NUMERIC(8,2) NOT NULL,
    max_z_mm        NUMERIC(8,2) NOT NULL,
    tolerance_mm    NUMERIC(6,3),
    min_feature_mm  NUMERIC(6,3),
    layer_min_mm    NUMERIC(6,3),
    surface_finish  TEXT CHECK (
        surface_finish IN ('rough','standard','fine','mirror')
    ),
    notes           TEXT
);

CREATE TABLE IF NOT EXISTS machine_material (
    machine_id      BIGINT NOT NULL REFERENCES machine(id) ON DELETE CASCADE,
    material_code   TEXT NOT NULL REFERENCES material(code),
    cost_per_gram   NUMERIC(8,3),
    in_stock_g      NUMERIC(10,2) NOT NULL DEFAULT 0,
    reorder_at_g    NUMERIC(10,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (machine_id, material_code)
);

-- ====================================
-- SCHEDULING
-- ====================================

CREATE TABLE IF NOT EXISTS booking (
    id              BIGSERIAL PRIMARY KEY,
    machine_id      BIGINT NOT NULL REFERENCES machine(id),
    user_id         BIGINT NOT NULL REFERENCES app_user(id),
    slot            TSTZRANGE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'requested' CHECK (
        status IN ('requested','confirmed','cancelled','no_show','completed')
    ),
    is_block        BOOLEAN NOT NULL DEFAULT FALSE,
    block_reason    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    EXCLUDE USING gist (
        machine_id WITH =,
        slot WITH &&
    ) WHERE (status IN ('requested','confirmed'))
);

CREATE INDEX IF NOT EXISTS booking_slot_idx
    ON booking USING gist (slot);

CREATE INDEX IF NOT EXISTS booking_user_idx
    ON booking (user_id, created_at DESC);

-- ====================================
-- JOBS & QUOTES
-- ====================================

CREATE TABLE IF NOT EXISTS job (
    id              BIGSERIAL PRIMARY KEY,
    booking_id      BIGINT UNIQUE REFERENCES booking(id),
    user_id         BIGINT NOT NULL REFERENCES app_user(id),
    machine_id      BIGINT NOT NULL REFERENCES machine(id),
    material_code   TEXT REFERENCES material(code),
    title           TEXT NOT NULL,
    description     TEXT,
    req_x_mm        NUMERIC(8,2),
    req_y_mm        NUMERIC(8,2),
    req_z_mm        NUMERIC(8,2),
    req_tolerance_mm NUMERIC(6,3),
    quantity        INT NOT NULL DEFAULT 1,
    status          TEXT NOT NULL DEFAULT 'draft' CHECK (
        status IN (
            'draft','quote_pending','quote_sent','quote_accepted',
            'queued','setup','running','qc','ready','collected',
            'failed','cancelled'
        )
    ),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS job_file (
    id              BIGSERIAL PRIMARY KEY,
    job_id          BIGINT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
    filename        TEXT NOT NULL,
    storage_key     TEXT NOT NULL,
    kind            TEXT NOT NULL CHECK (
        kind IN ('model','drawing','gerber','photo','other')
    ),
    bytes           BIGINT,
    uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quote (
    id              BIGSERIAL PRIMARY KEY,
    job_id          BIGINT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
    version         INT NOT NULL DEFAULT 1,
    est_minutes     INT NOT NULL,
    machine_cost    NUMERIC(10,2) NOT NULL,
    material_grams  NUMERIC(10,2),
    material_cost   NUMERIC(10,2) NOT NULL DEFAULT 0,
    setup_cost      NUMERIC(10,2) NOT NULL DEFAULT 0,
    discount        NUMERIC(10,2) NOT NULL DEFAULT 0,
    total           NUMERIC(10,2) NOT NULL,
    source          TEXT NOT NULL CHECK (source IN ('auto','manual')),
    prepared_by     BIGINT REFERENCES app_user(id),
    valid_until     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (job_id, version)
);

CREATE TABLE IF NOT EXISTS job_event (
    id              BIGSERIAL PRIMARY KEY,
    job_id          BIGINT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
    from_status     TEXT,
    to_status       TEXT NOT NULL,
    note            TEXT,
    actor_id        BIGINT REFERENCES app_user(id),
    at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS job_event_job_idx
    ON job_event (job_id, at);

-- ====================================
-- VIEWS
-- ====================================

CREATE OR REPLACE VIEW v_machine_utilization AS
SELECT
    m.id AS machine_id,
    m.centre_id,
    c.name AS centre_name,
    m.make || ' ' || m.model AS machine,
    date_trunc('week', lower(b.slot)) AS week,
    COALESCE(
        SUM(EXTRACT(EPOCH FROM (upper(b.slot) - lower(b.slot))) / 3600.0),
        0
    ) AS booked_hours,
    COUNT(*) FILTER (WHERE b.status = 'no_show') AS no_shows
FROM machine m
JOIN centre c ON c.id = m.centre_id
LEFT JOIN booking b
    ON b.machine_id = m.id
    AND b.status IN ('confirmed','completed','no_show')
    AND NOT b.is_block
GROUP BY
    m.id,
    m.centre_id,
    c.name,
    m.make,
    m.model,
    date_trunc('week', lower(b.slot));

CREATE OR REPLACE VIEW v_material_alerts AS
SELECT
    c.name AS centre_name,
    m.make || ' ' || m.model AS machine,
    mat.label AS material,
    mm.in_stock_g,
    mm.reorder_at_g
FROM machine_material mm
JOIN machine m ON m.id = mm.machine_id
JOIN centre c ON c.id = m.centre_id
JOIN material mat ON mat.code = mm.material_code
WHERE mm.in_stock_g <= mm.reorder_at_g;