-- Jobs across the lifecycle, so the manager queue has realistic content.
-- Centre 1 (Visakhapatnam) is the demo centre; manager is user 3 (K. Prasad).

-- 1. A finished job waiting for pickup (Ravi, student, PLA bracket on Ultimaker S5)
INSERT INTO job (booking_id, user_id, machine_id, material_code, title, description,
                 req_x_mm, req_y_mm, req_z_mm, quantity, status)
VALUES (1, 1, 1, 'pla', 'Drone arm bracket',
        'Mounting bracket for quadcopter arm, needs to be rigid', 120, 60, 25, 4, 'ready')
        ON CONFLICT (booking_id) DO NOTHING;

-- 2. Job with quote already sent, awaiting innovator (Sneha, startup, resin part)
INSERT INTO job (booking_id, user_id, machine_id, material_code, title, description,
                 req_x_mm, req_y_mm, req_z_mm, quantity, status)
VALUES (2, 2, 2, 'resin_std', 'Micro-fluidic test chip',
        'Transparent flow chamber with 0.3mm channels', 60, 40, 8, 2, 'quote_sent')
        ON CONFLICT (booking_id) DO NOTHING;

-- 3. Fresh job needing a quote (Ravi, PLA housing)
INSERT INTO job (booking_id, user_id, machine_id, material_code, title, description,
                 req_x_mm, req_y_mm, req_z_mm, quantity, status)
SELECT NULL, 1, 1, 'pla', 'Sensor housing',
        'Enclosure for outdoor environmental monitor', 90, 90, 45, 1, 'quote_pending'
WHERE NOT EXISTS (SELECT 1 FROM job WHERE user_id=1 AND machine_id=1 AND title='Sensor housing');

-- 4. A job already mid-run (Sneha, aluminium on CNC)
INSERT INTO job (booking_id, user_id, machine_id, material_code, title, description,
                 req_x_mm, req_y_mm, req_z_mm, quantity, status)
SELECT NULL, 2, 3, 'al_6061', 'Jig plate',
        'Tooling fixture plate with precision bore holes', 200, 150, 20, 1, 'running'
WHERE NOT EXISTS (SELECT 1 FROM job WHERE user_id=2 AND machine_id=3 AND title='Jig plate');

-- 5. Fresh job needing a quote (Ravi, PLA gears)
INSERT INTO job (booking_id, user_id, machine_id, material_code, title, description,
                 req_x_mm, req_y_mm, req_z_mm, quantity, status)
SELECT NULL, 1, 1, 'pla', 'Gear prototype',
        'Test batch of planetary gear set', 40, 40, 15, 6, 'quote_pending'
WHERE NOT EXISTS (SELECT 1 FROM job WHERE user_id=1 AND machine_id=1 AND title='Gear prototype');

-- Quotes for jobs that have been priced
-- Job 1: 90 min on Ultimaker S5 (rate 350, 50% student discount), 85g PLA (Rs 2.5/g), Rs 100 setup -> Total Rs 575.00
INSERT INTO quote (job_id, version, est_minutes, machine_cost, material_grams, material_cost, setup_cost, discount, total, source, prepared_by, valid_until)
VALUES (1, 1, 90, 525.00, 85.00, 212.50, 100.00, 262.50, 575.00, 'manual', 3, now() + INTERVAL '7 days')
ON CONFLICT (job_id, version) DO NOTHING;

-- Job 2: 75 min on Form 3L (rate 600), 30g resin (Rs 8/g), Rs 150 setup -> Total Rs 1140.00
INSERT INTO quote (job_id, version, est_minutes, machine_cost, material_grams, material_cost, setup_cost, discount, total, source, prepared_by, valid_until)
VALUES (2, 1, 75, 750.00, 30.00, 240.00, 150.00, 0.00, 1140.00, 'manual', 3, now() + INTERVAL '7 days')
ON CONFLICT (job_id, version) DO NOTHING;

-- Job 4: 90 min on Haas Mini Mill (rate 1200), 250g Al 6061 (Rs 1.2/g), Rs 500 setup -> Total Rs 2600.00
INSERT INTO quote (job_id, version, est_minutes, machine_cost, material_grams, material_cost, setup_cost, discount, total, source, prepared_by, valid_until)
VALUES (4, 1, 90, 1800.00, 250.00, 300.00, 500.00, 0.00, 2600.00, 'manual', 3, now() + INTERVAL '7 days')
ON CONFLICT (job_id, version) DO NOTHING;

-- Audit event history
INSERT INTO job_event (job_id, from_status, to_status, note, actor_id, at)
SELECT v.job_id, v.from_status, v.to_status, v.note, v.actor_id, v.at
FROM (VALUES
(1, 'draft', 'quote_pending', 'Job submitted by innovator', 1, now() - INTERVAL '3 days'),
(1, 'quote_pending', 'quote_sent', 'Quote v1 issued: Rs 575.00', 3, now() - INTERVAL '2 days'),
(1, 'quote_sent', 'quote_accepted', 'Innovator accepted quote', 1, now() - INTERVAL '2 days'),
(1, 'quote_accepted', 'queued', 'Scheduled for production', 3, now() - INTERVAL '1 day'),
(1, 'queued', 'setup', 'Loaded PLA spool', 3, now() - INTERVAL '6 hours'),
(1, 'setup', 'running', 'Print started', 3, now() - INTERVAL '5 hours'),
(1, 'running', 'qc', 'Print completed, dimensional inspection', 3, now() - INTERVAL '2 hours'),
(1, 'qc', 'ready', 'Passed QC inspection. Placed on pickup shelf.', 3, now() - INTERVAL '1 hour'),

(2, 'draft', 'quote_pending', 'Job submitted by innovator', 2, now() - INTERVAL '1 day'),
(2, 'quote_pending', 'quote_sent', 'Quote v1 issued: Rs 1140.00', 3, now() - INTERVAL '12 hours'),

(3, 'draft', 'quote_pending', 'Job submitted by innovator', 1, now() - INTERVAL '2 hours'),

(4, 'draft', 'quote_pending', 'Job submitted by innovator', 2, now() - INTERVAL '2 days'),
(4, 'quote_pending', 'quote_sent', 'Quote v1 issued: Rs 2600.00', 3, now() - INTERVAL '1 day'),
(4, 'quote_sent', 'quote_accepted', 'Innovator accepted quote', 2, now() - INTERVAL '1 day'),
(4, 'quote_accepted', 'queued', 'Placed in milling queue', 3, now() - INTERVAL '18 hours'),
(4, 'queued', 'setup', 'Stock clamped, tools calibrated', 3, now() - INTERVAL '3 hours'),
(4, 'setup', 'running', 'CNC program cycle started', 3, now() - INTERVAL '1 hour'),

(5, 'draft', 'quote_pending', 'Job submitted by innovator', 1, now() - INTERVAL '30 minutes')
) AS v(job_id, from_status, to_status, note, actor_id, at)
WHERE NOT EXISTS (SELECT 1 FROM job_event e WHERE e.job_id=v.job_id AND e.to_status=v.to_status AND e.note=v.note);

