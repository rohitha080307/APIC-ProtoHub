-- APIC ProtoHub: machine matching and free-slot functions
-- Corrected to use machine_capability from schema.sql
-- Run this file in the apic_protohub database.

-- ============================================================
-- 1. MACHINE MATCHING
-- ============================================================

CREATE OR REPLACE FUNCTION match_machines(
    p_x_mm            NUMERIC,
    p_y_mm            NUMERIC,
    p_z_mm            NUMERIC,
    p_material        TEXT DEFAULT NULL,
    p_tolerance_mm    NUMERIC DEFAULT NULL,
    p_min_feature_mm  NUMERIC DEFAULT NULL,
    p_lat             NUMERIC DEFAULT NULL,
    p_lng             NUMERIC DEFAULT NULL,
    p_quantity        INT DEFAULT 1
)
RETURNS TABLE (
    machine_id      BIGINT,
    centre_name     TEXT,
    district        TEXT,
    machine_name    TEXT,
    process_label   TEXT,
    distance_km     NUMERIC,
    status          TEXT,
    rate_per_hour   NUMERIC,
    material_ok     BOOLEAN,
    in_stock_g      NUMERIC,
    fit_score       NUMERIC,
    reason          TEXT
)
AS $$
BEGIN
    -- Validate required dimensions and quantity.
    IF p_x_mm IS NULL OR p_y_mm IS NULL OR p_z_mm IS NULL
       OR p_x_mm <= 0 OR p_y_mm <= 0 OR p_z_mm <= 0
       OR p_quantity IS NULL OR p_quantity <= 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH oriented AS (
        -- Compare largest part dimension with largest machine dimension.
        SELECT
            GREATEST(p_x_mm, p_y_mm, p_z_mm) AS d1,
            (p_x_mm + p_y_mm + p_z_mm)
                - GREATEST(p_x_mm, p_y_mm, p_z_mm)
                - LEAST(p_x_mm, p_y_mm, p_z_mm) AS d2,
            LEAST(p_x_mm, p_y_mm, p_z_mm) AS d3
    ),
    matched AS (
        SELECT
            m.id AS machine_id,
            c.name AS centre_name,
            c.district AS district,
            (m.make || ' ' || m.model)::TEXT AS machine_name,
            pr.layman_label::TEXT AS process_label,

            ROUND(
                CASE
                    WHEN p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
                        (
                            6371 * ACOS(
                                LEAST(1.0, GREATEST(-1.0,
                                    COS(RADIANS(p_lat)) * COS(RADIANS(c.lat))
                                    * COS(RADIANS(c.lng) - RADIANS(p_lng))
                                    + SIN(RADIANS(p_lat)) * SIN(RADIANS(c.lat))
                                ))
                            )
                        )::NUMERIC
                    ELSE 0.0
                END,
                1
            ) AS distance_km,

            m.status::TEXT AS status,
            m.rate_per_hour AS rate_per_hour,

            COALESCE(mm.material_ok, p_material IS NULL) AS material_ok,
            COALESCE(mm.in_stock_g, 0::NUMERIC) AS in_stock_g,

            ROUND(
                (
                    (o.d1 / cap.max_x_mm)
                    * (o.d2 / cap.max_y_mm)
                    * (o.d3 / cap.max_z_mm)
                )::NUMERIC,
                3
            ) AS fit_score,

            CONCAT_WS(
                '; ',
                'fits ' ||
                    ROUND(cap.max_x_mm) || '×' ||
                    ROUND(cap.max_y_mm) || '×' ||
                    ROUND(cap.max_z_mm) || 'mm',

                CASE
                    WHEN cap.tolerance_mm IS NOT NULL
                    THEN 'holds ±' || cap.tolerance_mm || 'mm'
                END,

                CASE
                    WHEN mm.in_stock_g > 0 AND p_material IS NOT NULL
                    THEN ROUND(mm.in_stock_g) || 'g in stock'
                    WHEN mm.in_stock_g > 0
                    THEN 'materials in stock'
                END,

                CASE
                    WHEN m.status <> 'available'
                    THEN 'currently ' || m.status
                END
            )::TEXT AS reason

        FROM machine m
        JOIN centre c
            ON c.id = m.centre_id
           AND c.is_live = TRUE

        JOIN process pr
            ON pr.code = m.process_code

        -- Correct schema table: machine_capability, not envelope.
        JOIN machine_capability cap
            ON cap.machine_id = m.id

        CROSS JOIN oriented o

        -- Aggregate materials so a machine is not duplicated per material.
        LEFT JOIN LATERAL (
            SELECT
                BOOL_OR(mm_sub.material_code IS NOT NULL) AS material_ok,
                COALESCE(SUM(mm_sub.in_stock_g), 0::NUMERIC) AS in_stock_g
            FROM machine_material mm_sub
            WHERE mm_sub.machine_id = m.id
              AND (
                    p_material IS NULL
                    OR mm_sub.material_code = p_material
                  )
        ) mm ON TRUE

        WHERE
            -- Part must physically fit.
            o.d1 <= cap.max_x_mm
            AND o.d2 <= cap.max_y_mm
            AND o.d3 <= cap.max_z_mm

            -- If material is specified, the machine must support it.
            AND (
                p_material IS NULL
                OR mm.material_ok IS TRUE
            )

            -- Machine must meet the requested tolerance.
            AND (
                p_tolerance_mm IS NULL
                OR (
                    cap.tolerance_mm IS NOT NULL
                    AND cap.tolerance_mm <= p_tolerance_mm
                )
            )

            -- Machine must support the requested smallest feature.
            AND (
                p_min_feature_mm IS NULL
                OR (
                    cap.min_feature_mm IS NOT NULL
                    AND cap.min_feature_mm <= p_min_feature_mm
                )
            )

            -- If material is specified, some stock must be available.
            AND (
                p_material IS NULL
                OR mm.in_stock_g > 0
            )

            -- Exclude machines that cannot currently be used.
            AND m.status NOT IN ('maintenance', 'broken', 'retired')
    )
    SELECT
        r.machine_id,
        r.centre_name,
        r.district,
        r.machine_name,
        r.process_label,
        r.distance_km,
        r.status,
        r.rate_per_hour,
        r.material_ok,
        r.in_stock_g,
        r.fit_score,
        r.reason
    FROM matched r
    ORDER BY
        (r.status = 'available') DESC,
        r.distance_km ASC,
        r.fit_score DESC;

END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================
-- 2. FREE SLOT FINDER
-- ============================================================

CREATE OR REPLACE FUNCTION free_slots(
    p_machine_id    BIGINT,
    p_from          DATE,
    p_days          INT DEFAULT 7,
    p_slot_minutes  INT DEFAULT 60
)
RETURNS TABLE (
    slot_start TIMESTAMPTZ,
    slot_end   TIMESTAMPTZ
)
AS $$
BEGIN
    IF p_machine_id IS NULL
       OR p_from IS NULL
       OR p_days IS NULL
       OR p_days <= 0
       OR p_slot_minutes IS NULL
       OR p_slot_minutes <= 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH cfg AS (
        SELECT
            c.opens_at,
            c.closes_at,
            c.working_days
        FROM machine m
        JOIN centre c ON c.id = m.centre_id
        WHERE m.id = p_machine_id
    ),
    days AS (
        SELECT d::DATE AS day
        FROM generate_series(
            p_from::TIMESTAMP,
            (p_from + (p_days - 1))::TIMESTAMP,
            INTERVAL '1 day'
        ) d
        CROSS JOIN cfg
        WHERE EXTRACT(ISODOW FROM d)::INT = ANY (cfg.working_days)
    ),
    candidates AS (
        SELECT
            (
                d.day + cfg.opens_at
            )::TIMESTAMPTZ
            + (
                n * (p_slot_minutes || ' minutes')::INTERVAL
            ) AS s
        FROM days d
        CROSS JOIN cfg
        CROSS JOIN generate_series(
            0,
            (
                EXTRACT(EPOCH FROM (cfg.closes_at - cfg.opens_at))
                / 60 / p_slot_minutes
            )::INT - 1
        ) n
    )
    SELECT
        c.s,
        c.s + (p_slot_minutes || ' minutes')::INTERVAL
    FROM candidates c
    CROSS JOIN cfg
    WHERE
        c.s > NOW()

        -- Slot must finish before closing time.
        AND (
            c.s + (p_slot_minutes || ' minutes')::INTERVAL
        )::TIME <= cfg.closes_at

        -- Exclude slots that overlap an existing booking.
        AND NOT EXISTS (
            SELECT 1
            FROM booking b
            WHERE b.machine_id = p_machine_id
              AND b.status IN ('requested', 'confirmed')
              AND b.slot && tstzrange(
                    c.s,
                    c.s + (p_slot_minutes || ' minutes')::INTERVAL
                  )
        )
    ORDER BY c.s;

END;
$$ LANGUAGE plpgsql STABLE;