
-- Seed data. Machine specs are realistic for the actual models named.

-- ---- Processes ----
INSERT INTO process (code, family, label, layman_label) VALUES
('fdm',      'additive',    'FDM 3D Printing',        'Plastic 3D printing'),
('sla',      'additive',    'SLA/Resin 3D Printing',  'Resin 3D printing (fine detail)'),
('sls',      'additive',    'SLS Nylon Printing',     'Nylon 3D printing (strong parts)'),
('cnc_mill', 'subtractive', '3-Axis CNC Milling',     'Metal/plastic machining'),
('laser_cut','subtractive', 'CO2 Laser Cutting',      'Sheet cutting & engraving'),
('pcb',      'electronics', 'PCB Prototyping',        'Circuit board making')
ON CONFLICT (code) DO NOTHING;


-- ---- Materials ----
INSERT INTO material (code, label, class, density_g_cm3) VALUES
('pla',       'PLA',             'thermoplastic', 1.240),
('abs',       'ABS',             'thermoplastic', 1.040),
('petg',      'PETG',            'thermoplastic', 1.270),
('nylon_pa12','Nylon PA12',      'thermoplastic', 1.010),
('resin_std', 'Standard Resin',  'resin',         1.100),
('al_6061',   'Aluminium 6061',  'metal',         2.700),
('acrylic',   'Acrylic Sheet',   'other',         1.180),
('mdf',       'MDF Board',       'wood',          0.750),
('fr4',       'FR4 Copper-Clad', 'composite',     1.850)
ON CONFLICT (code) DO NOTHING;


-- ---- Centres ----
INSERT INTO centre (name, district, address, lat, lng, phone, is_live)
SELECT v.name, v.district, v.address, v.lat, v.lng, v.phone, v.is_live
FROM (VALUES
('APIC Visakhapatnam', 'Visakhapatnam',
 'AU Engineering College Campus, Visakhapatnam',
 17.730000, 83.319000, '0891-2844000', TRUE),

('APIC Vijayawada', 'NTR',
 'Siddhartha Engineering College, Vijayawada',
 16.506100, 80.648000, '0866-2582333', TRUE),

('APIC Tirupati', 'Tirupati',
 'SVU Campus, Tirupati',
 13.628700, 79.419200, '0877-2289000', TRUE),

('APIC Kakinada', 'Kakinada',
 'JNTU-K Campus, Kakinada',
 16.989400, 82.247500, '0884-2300900', TRUE),

('APIC Anantapur', 'Anantapur',
 'JNTU-A Campus, Anantapur',
 14.681500, 77.600400, '08554-272000', FALSE)
) AS v(name, district, address, lat, lng, phone, is_live)
WHERE NOT EXISTS (
    SELECT 1
    FROM centre c
    WHERE c.name = v.name
);


-- ---- Users ----
INSERT INTO app_user (phone, name, role, centre_id, affiliation, institution) VALUES
('+919000000001', 'Ravi Teja',      'innovator',      NULL, 'student',  'JNTU Kakinada'),
('+919000000002', 'Sneha Reddy',    'innovator',      NULL, 'startup',  'HydroFilter Labs'),
('+919000000003', 'K. Prasad',      'centre_manager', 1,    NULL,       NULL),
('+919000000004', 'M. Lakshmi',     'centre_staff',   2,    NULL,       NULL),
('+919000000005', 'APIS Admin',     'apis_admin',     NULL, NULL,       NULL)
ON CONFLICT (phone) DO NOTHING;


-- ---- Visakhapatnam (well equipped) ----
INSERT INTO machine
(centre_id, process_code, make, model, asset_tag, status,
 rate_per_hour, setup_fee, min_charge, student_discount_pct)
VALUES
(1, 'fdm',       'Ultimaker', 'S5',            'VZG-3DP-001', 'available',    350.00, 100.00,  200.00, 50),
(1, 'sla',       'Formlabs',  'Form 3L',       'VZG-SLA-001', 'available',    600.00, 150.00,  400.00, 40),
(1, 'cnc_mill',  'Haas',      'Mini Mill',     'VZG-CNC-001', 'available',   1200.00, 500.00, 1000.00, 30),
(1, 'laser_cut', 'Trotec',    'Speedy 400',    'VZG-LSR-001', 'maintenance',  450.00, 100.00,  250.00, 40)
ON CONFLICT (centre_id, asset_tag) DO NOTHING;


-- ---- Vijayawada ----
INSERT INTO machine
(centre_id, process_code, make, model, asset_tag, status,
 rate_per_hour, setup_fee, min_charge, student_discount_pct)
VALUES
(2, 'fdm', 'Creality', 'K1 Max',        'VJA-3DP-001', 'available', 250.00,  50.00, 150.00, 50),
(2, 'fdm', 'Prusa',    'MK4',           'VJA-3DP-002', 'available', 200.00,  50.00, 150.00, 50),
(2, 'pcb', 'LPKF',     'ProtoMat S104', 'VJA-PCB-001', 'available', 800.00, 200.00, 500.00, 40)
ON CONFLICT (centre_id, asset_tag) DO NOTHING;


-- ---- Tirupati (has the big SLS) ----
INSERT INTO machine
(centre_id, process_code, make, model, asset_tag, status,
 rate_per_hour, setup_fee, min_charge, student_discount_pct)
VALUES
(3, 'sls', 'EOS',       'P 396', 'TPT-SLS-001', 'available', 2500.00, 800.00, 2000.00, 25),
(3, 'fdm', 'Ultimaker', 'S3',    'TPT-3DP-001', 'available',  300.00, 100.00,  200.00, 50)
ON CONFLICT (centre_id, asset_tag) DO NOTHING;


-- ---- Kakinada (modest) ----
INSERT INTO machine
(centre_id, process_code, make, model, asset_tag, status,
 rate_per_hour, setup_fee, min_charge, student_discount_pct)
VALUES
(4, 'fdm',       'Creality', 'Ender-3 V3',    'KKD-3DP-001', 'available', 150.00,  50.00, 100.00, 50),
(4, 'laser_cut', 'GCC',      'LaserPro C180', 'KKD-LSR-001', 'available', 350.00, 100.00, 200.00, 40)
ON CONFLICT (centre_id, asset_tag) DO NOTHING;


-- ---- Anantapur (centre not live, machines shouldn't appear in search) ----
INSERT INTO machine
(centre_id, process_code, make, model, asset_tag, status,
 rate_per_hour, setup_fee, min_charge, student_discount_pct)
VALUES
(5, 'fdm', 'Bambu Lab', 'X1 Carbon', 'ATP-3DP-001', 'available', 300.00, 100.00, 200.00, 50)
ON CONFLICT (centre_id, asset_tag) DO NOTHING;


-- ---- Capabilities (real specs for these models) ----
INSERT INTO machine_capability
(machine_id, max_x_mm, max_y_mm, max_z_mm, tolerance_mm,
 min_feature_mm, layer_min_mm, surface_finish)
VALUES
(1,  330, 240, 300, 0.200, 0.800, 0.020, 'standard'),  -- Ultimaker S5
(2,  335, 200, 300, 0.100, 0.300, 0.025, 'fine'),      -- Form 3L
(3,  406, 305, 254, 0.013, 0.200, NULL,  'mirror'),    -- Haas Mini Mill
(4, 1000, 610, 305, 0.100, 0.100, NULL,  'standard'),  -- Trotec Speedy 400
(5,  300, 300, 300, 0.200, 0.800, 0.050, 'standard'),  -- Creality K1 Max
(6,  250, 210, 220, 0.150, 0.400, 0.050, 'fine'),      -- Prusa MK4
(7,  229, 305, 100, 0.050, 0.150, NULL,  'fine'),      -- LPKF S104
(8,  340, 340, 600, 0.150, 0.500, 0.060, 'standard'),  -- EOS P 396
(9,  230, 190, 200, 0.200, 0.800, 0.020, 'standard'),  -- Ultimaker S3
(10, 220, 220, 250, 0.300, 1.000, 0.100, 'rough'),     -- Ender-3 V3
(11, 300, 200,  50, 0.100, 0.100, NULL,  'standard'),  -- GCC C180
(12, 256, 256, 256, 0.150, 0.400, 0.020, 'fine')       -- Bambu X1C (Anantapur)
ON CONFLICT (machine_id) DO NOTHING;


-- ---- Machine materials ----
INSERT INTO machine_material
(machine_id, material_code, cost_per_gram, in_stock_g, reorder_at_g)
VALUES
(1, 'pla',  2.50,  4000,  500),
(1, 'abs',  3.00,  2000,  500),
(1, 'petg', 3.20,  1500,  500),
(2, 'resin_std', 8.00, 3000, 500),
(3, 'al_6061', 1.20, 25000, 5000),
(4, 'acrylic', 0.90, 12000, 2000),
(4, 'mdf',     0.40, 20000, 3000),
(5, 'pla',  2.20, 3000, 500),
(5, 'petg', 3.00,  800, 500),
(6, 'pla',  2.20,  250, 500),       -- low stock, should trigger alert
(7, 'fr4',  4.50, 2200, 500)
ON CONFLICT (machine_id, material_code) DO NOTHING;


INSERT INTO machine_material
(machine_id, material_code, cost_per_gram, in_stock_g, reorder_at_g)
VALUES
(8,  'nylon_pa12', 6.50, 15000, 3000),
(9,  'pla',        2.50,  1800,  500),
(10, 'pla',        2.00,   600,  400),
(11, 'acrylic',    0.90,  5000, 1000),
(11, 'mdf',        0.40,  8000, 2000),
(12, 'pla',        2.20,  2000,  500)
ON CONFLICT (machine_id, material_code) DO NOTHING;


-- ---- A couple of existing bookings so free_slots has something to route around ----
INSERT INTO booking (machine_id, user_id, slot, status)
SELECT 1, 1,
       tstzrange(
           CURRENT_DATE + INTERVAL '1 day 10 hours',
           CURRENT_DATE + INTERVAL '1 day 12 hours',
           '[)'
       ),
       'requested'
WHERE NOT EXISTS (
    SELECT 1
    FROM booking
    WHERE machine_id = 1
      AND user_id = 1
      AND slot = tstzrange(
          CURRENT_DATE + INTERVAL '1 day 10 hours',
          CURRENT_DATE + INTERVAL '1 day 12 hours',
          '[)'
      )
);


INSERT INTO booking (machine_id, user_id, slot, status)
SELECT 2, 2,
       tstzrange(
           CURRENT_DATE + INTERVAL '1 day 14 hours',
           CURRENT_DATE + INTERVAL '1 day 16 hours',
           '[)'
       ),
       'requested'
WHERE NOT EXISTS (
    SELECT 1
    FROM booking
    WHERE machine_id = 2
      AND user_id = 2
      AND slot = tstzrange(
          CURRENT_DATE + INTERVAL '1 day 14 hours',
          CURRENT_DATE + INTERVAL '1 day 16 hours',
          '[)'
      )
);

