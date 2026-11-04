-- ============================================================
-- MANAGER OPERATIONS — extends schema.sql
-- Everything a centre manager needs to ACT, plus the views the
-- dashboard reads. Design principle: a manager should never have
-- to think about SQL state — the queue tells them what needs doing.
-- ============================================================

-- Stock movements as a ledger, not a mutable number.
-- Every consume/restock/adjust is recorded as a row.
CREATE TABLE IF NOT EXISTS stock_movement (
    id              BIGSERIAL PRIMARY KEY,
    machine_id      BIGINT NOT NULL REFERENCES machine(id),
    material_code   TEXT NOT NULL REFERENCES material(code),
    delta_g         NUMERIC(10,2) NOT NULL,
    reason          TEXT NOT NULL CHECK (reason IN
                        ('restock','job_consume','adjustment','waste','stocktake')),
    job_id          BIGINT REFERENCES job(id),
    actor_id        BIGINT REFERENCES app_user(id),
    note            TEXT,
    at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (machine_id, material_code)
        REFERENCES machine_material(machine_id, material_code)
);

CREATE INDEX IF NOT EXISTS stock_mv_idx
    ON stock_movement (machine_id, material_code, at);

-- Keep machine_material.in_stock_g as the running balance.
CREATE OR REPLACE FUNCTION apply_stock_movement()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE machine_material
       SET in_stock_g = in_stock_g + NEW.delta_g
     WHERE machine_id = NEW.machine_id
       AND material_code = NEW.material_code
       AND in_stock_g + NEW.delta_g >= 0;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'stock movement would make stock negative or material row is missing';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_stock_movement ON stock_movement;

CREATE TRIGGER trg_stock_movement
    AFTER INSERT ON stock_movement
    FOR EACH ROW
    EXECUTE FUNCTION apply_stock_movement();

-- ============================================================
-- JOB ACTIONS
-- ============================================================

-- Advance a job through its lifecycle.
CREATE OR REPLACE FUNCTION advance_job(
    p_job_id    BIGINT,
    p_to        TEXT,
    p_actor     BIGINT,
    p_note      TEXT DEFAULT NULL,
    p_grams     NUMERIC DEFAULT NULL
)
RETURNS TEXT AS $$
DECLARE
    v_from      TEXT;
    v_machine   BIGINT;
    v_material  TEXT;
    v_allowed   BOOLEAN;
    v_have      NUMERIC;
BEGIN
    SELECT status, machine_id, material_code
      INTO v_from, v_machine, v_material
      FROM job
     WHERE id = p_job_id
     FOR UPDATE;

    IF v_from IS NULL THEN
        RAISE EXCEPTION 'job % not found', p_job_id;
    END IF;

    -- Valid job-status transitions
    v_allowed := CASE
        WHEN v_from = 'draft'
             AND p_to = 'quote_pending' THEN TRUE

        WHEN v_from = 'quote_sent'
             AND p_to = 'quote_accepted' THEN TRUE

        WHEN v_from = 'quote_accepted'
             AND p_to = 'queued' THEN TRUE

        WHEN v_from = 'queued'
             AND p_to = 'setup' THEN TRUE

        WHEN v_from = 'setup'
             AND p_to = 'running' THEN TRUE

        WHEN v_from = 'running'
             AND p_to = 'qc' THEN TRUE

        WHEN v_from = 'qc'
             AND p_to = 'ready' THEN TRUE

        WHEN v_from = 'qc'
             AND p_to = 'running' THEN TRUE

        WHEN p_to = 'failed'
             AND v_from IN ('queued','setup','running','qc') THEN TRUE

        WHEN p_to = 'cancelled'
             AND v_from IN (
                 'draft','quote_pending','quote_sent',
                 'quote_accepted','queued','setup'
             ) THEN TRUE

        ELSE FALSE
    END;

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'illegal transition: % -> %', v_from, p_to;
    END IF;

    IF p_grams IS NOT NULL AND p_grams <= 0 THEN
        RAISE EXCEPTION 'material grams must be greater than zero';
    END IF;

    -- Consume material when a run starts.
    -- Rework can consume additional grams on a later run.
    IF p_grams IS NOT NULL
       AND v_material IS NOT NULL
       AND p_to = 'running' THEN

        SELECT in_stock_g
          INTO v_have
          FROM machine_material
         WHERE machine_id = v_machine
           AND material_code = v_material
         FOR UPDATE;

        IF v_have IS NULL OR v_have < p_grams THEN
            RAISE EXCEPTION
                'insufficient stock: need %g of %, only %g on hand',
                p_grams, v_material, COALESCE(v_have,0);
        END IF;

        INSERT INTO stock_movement (
            machine_id,
            material_code,
            delta_g,
            reason,
            job_id,
            actor_id
        )
        VALUES (
            v_machine,
            v_material,
            -p_grams,
            'job_consume',
            p_job_id,
            p_actor
        );
    END IF;

    UPDATE job
       SET status = p_to
     WHERE id = p_job_id;

    INSERT INTO job_event (
        job_id,
        from_status,
        to_status,
        note,
        actor_id
    )
    VALUES (
        p_job_id,
        v_from,
        p_to,
        p_note,
        p_actor
    );

    RETURN p_to;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- ISSUE A QUOTE
-- ============================================================

CREATE OR REPLACE FUNCTION issue_quote(
    p_job_id    BIGINT,
    p_actor     BIGINT,
    p_minutes   INT,
    p_grams     NUMERIC DEFAULT NULL,
    p_note      TEXT DEFAULT NULL
)
RETURNS NUMERIC AS $$
DECLARE
    v_machine   RECORD;
    v_matcost   NUMERIC := 0;
    v_disc      NUMERIC := 0;
    v_machcost  NUMERIC;
    v_total     NUMERIC;
    v_ver       INT;
BEGIN
    SELECT
        m.rate_per_hour,
        m.setup_fee,
        m.min_charge,
        m.student_discount_pct,
        j.material_code,
        au.affiliation,
        j.status
    INTO v_machine
    FROM job j
    JOIN machine m
      ON m.id = j.machine_id
    JOIN app_user au
      ON au.id = j.user_id
    WHERE j.id = p_job_id
    FOR UPDATE OF j;

    IF v_machine IS NULL THEN
        RAISE EXCEPTION 'job % not found', p_job_id;
    END IF;

    IF p_minutes IS NULL OR p_minutes <= 0 THEN
        RAISE EXCEPTION 'estimated minutes must be greater than zero';
    END IF;

    IF p_grams IS NOT NULL AND p_grams < 0 THEN
        RAISE EXCEPTION 'material grams cannot be negative';
    END IF;

    IF v_machine.status NOT IN ('quote_pending','quote_sent') THEN
        RAISE EXCEPTION
            'job must be awaiting a quote; current status is %',
            v_machine.status;
    END IF;

    -- Machine time cost
    v_machcost :=
        ROUND(v_machine.rate_per_hour * p_minutes / 60.0, 2);

    -- Material cost
    IF p_grams IS NOT NULL
       AND v_machine.material_code IS NOT NULL THEN

        SELECT COALESCE(mm.cost_per_gram,0) * p_grams
          INTO v_matcost
          FROM machine_material mm
          JOIN job j
            ON j.machine_id = mm.machine_id
         WHERE j.id = p_job_id
           AND mm.material_code = v_machine.material_code;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'machine does not support material %',
                v_machine.material_code;
        END IF;
    END IF;

    -- Student discount applies to machine time only
    IF v_machine.affiliation = 'student' THEN
        v_disc :=
            ROUND(
                v_machcost * v_machine.student_discount_pct / 100.0,
                2
            );
    END IF;

    v_total := GREATEST(
        v_machcost
        + COALESCE(v_matcost,0)
        + v_machine.setup_fee
        - v_disc,
        v_machine.min_charge
    );

    SELECT COALESCE(MAX(version),0) + 1
      INTO v_ver
      FROM quote
     WHERE job_id = p_job_id;

    INSERT INTO quote (
        job_id,
        version,
        est_minutes,
        machine_cost,
        material_grams,
        material_cost,
        setup_cost,
        discount,
        total,
        source,
        prepared_by,
        valid_until
    )
    VALUES (
        p_job_id,
        v_ver,
        p_minutes,
        v_machcost,
        p_grams,
        COALESCE(v_matcost,0),
        v_machine.setup_fee,
        v_disc,
        v_total,
        'manual',
        p_actor,
        now() + INTERVAL '7 days'
    );

    UPDATE job
       SET status = 'quote_sent'
     WHERE id = p_job_id;

    INSERT INTO job_event (
        job_id,
        from_status,
        to_status,
        note,
        actor_id
    )
    VALUES (
        p_job_id,
        v_machine.status,
        'quote_sent',
        COALESCE(
            p_note,
            'Quote v' || v_ver || ' issued: Rs ' || v_total
        ),
        p_actor
    );

    RETURN v_total;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- DASHBOARD VIEWS
-- ============================================================

-- Manager queue: jobs requiring attention, most urgent first.
CREATE OR REPLACE VIEW v_manager_queue AS
SELECT
    j.id AS job_id,
    j.title,
    j.status,
    m.centre_id,
    c.name AS centre_name,
    m.make || ' ' || m.model AS machine,
    u.name AS innovator,
    u.affiliation,
    u.phone,
    j.material_code,
    j.quantity,
    b.slot,
    lower(b.slot) AS slot_start,
    q.total AS current_quote,

    CASE j.status
        WHEN 'quote_pending'  THEN 'Price this job'
        WHEN 'quote_sent'     THEN 'Awaiting innovator'
        WHEN 'quote_accepted' THEN 'Add to queue'
        WHEN 'queued'         THEN 'Start setup'
        WHEN 'setup'          THEN 'Begin run'
        WHEN 'running'        THEN 'Move to QC when done'
        WHEN 'qc'             THEN 'Pass or rework'
        WHEN 'ready'          THEN 'Awaiting collection'
    END AS next_action,

    CASE
        WHEN j.status = 'quote_pending' THEN 0
        WHEN lower(b.slot)::date = CURRENT_DATE THEN 1
        WHEN j.status IN ('setup','running','qc') THEN 2
        ELSE 3
    END AS priority,

    j.created_at

FROM job j
JOIN machine m
  ON m.id = j.machine_id
JOIN centre c
  ON c.id = m.centre_id
JOIN app_user u
  ON u.id = j.user_id
LEFT JOIN booking b
  ON b.id = j.booking_id
LEFT JOIN LATERAL (
    SELECT total
      FROM quote
     WHERE job_id = j.id
     ORDER BY version DESC
     LIMIT 1
) q ON TRUE

WHERE j.status NOT IN (
    'draft','collected','cancelled','failed'
)

ORDER BY
    priority,
    slot_start NULLS LAST,
    j.created_at;

-- Centre health summary for today's dashboard.
CREATE OR REPLACE VIEW v_centre_today AS
SELECT
    c.id AS centre_id,
    c.name AS centre_name,

    (
        SELECT COUNT(*)
        FROM job j
        JOIN machine m ON m.id = j.machine_id
        WHERE m.centre_id = c.id
          AND j.status = 'quote_pending'
    ) AS awaiting_quote,

    (
        SELECT COUNT(*)
        FROM job j
        JOIN machine m ON m.id = j.machine_id
        WHERE m.centre_id = c.id
          AND j.status IN ('queued','setup','running','qc')
    ) AS active_jobs,

    (
        SELECT COUNT(*)
        FROM job j
        JOIN machine m ON m.id = j.machine_id
        WHERE m.centre_id = c.id
          AND j.status = 'ready'
    ) AS ready_pickup,

    (
        SELECT COUNT(*)
        FROM booking b
        JOIN machine m ON m.id = b.machine_id
        WHERE m.centre_id = c.id
          AND lower(b.slot)::date = CURRENT_DATE
          AND b.status IN ('requested','confirmed')
    ) AS todays_bookings,

    (
        SELECT COUNT(*)
        FROM machine mm
        WHERE mm.centre_id = c.id
          AND mm.status = 'available'
    ) AS machines_up,

    (
        SELECT COUNT(*)
        FROM machine mm
        WHERE mm.centre_id = c.id
          AND mm.status IN ('maintenance','broken')
    ) AS machines_down,

    (
        SELECT COUNT(*)
        FROM v_material_alerts va
        WHERE va.centre_name = c.name
    ) AS low_stock_items

FROM centre c
WHERE c.is_live;