-- ============================================================
-- Community Medicine Availability & Shortage Alert System
-- MySQL Schema
-- ============================================================

CREATE DATABASE IF NOT EXISTS medicine_db;
USE medicine_db;

-- ============================================================
-- TABLE: Pharmacy
-- ============================================================
CREATE TABLE IF NOT EXISTS Pharmacy (
    pharmacy_id INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(150) NOT NULL,
    area        VARCHAR(100) NOT NULL,
    contact     VARCHAR(20)  NOT NULL
);

-- ============================================================
-- TABLE: Medicine
-- ============================================================
CREATE TABLE IF NOT EXISTS Medicine (
    medicine_id  INT AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    category     VARCHAR(100) NOT NULL,
    life_saving  TINYINT(1)   NOT NULL DEFAULT 0  -- 1 = Yes, 0 = No
);

-- ============================================================
-- TABLE: Stock
-- ============================================================
CREATE TABLE IF NOT EXISTS Stock (
    stock_id    INT AUTO_INCREMENT PRIMARY KEY,
    pharmacy_id INT NOT NULL,
    medicine_id INT NOT NULL,
    quantity    INT NOT NULL DEFAULT 0,
    threshold   INT NOT NULL DEFAULT 10,
    CONSTRAINT fk_stock_pharmacy FOREIGN KEY (pharmacy_id) REFERENCES Pharmacy(pharmacy_id) ON DELETE CASCADE,
    CONSTRAINT fk_stock_medicine FOREIGN KEY (medicine_id) REFERENCES Medicine(medicine_id) ON DELETE CASCADE,
    CONSTRAINT chk_quantity  CHECK (quantity  >= 0),
    CONSTRAINT chk_threshold CHECK (threshold >  0),
    UNIQUE KEY uq_pharmacy_medicine (pharmacy_id, medicine_id)
);

-- ============================================================
-- TABLE: Alert
-- ============================================================
CREATE TABLE IF NOT EXISTS Alert (
    alert_id    INT AUTO_INCREMENT PRIMARY KEY,
    pharmacy_id INT  NOT NULL,
    medicine_id INT  NOT NULL,
    message     TEXT NOT NULL,
    alert_date  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_alert_pharmacy FOREIGN KEY (pharmacy_id) REFERENCES Pharmacy(pharmacy_id) ON DELETE CASCADE,
    CONSTRAINT fk_alert_medicine FOREIGN KEY (medicine_id) REFERENCES Medicine(medicine_id) ON DELETE CASCADE
);

-- ============================================================
-- TRIGGER: Auto-insert alert when stock < threshold
-- ============================================================
DELIMITER $$

CREATE TRIGGER trg_low_stock_alert
AFTER UPDATE ON Stock
FOR EACH ROW
BEGIN
    IF NEW.quantity < NEW.threshold THEN
        INSERT INTO Alert (pharmacy_id, medicine_id, message)
        SELECT
            NEW.pharmacy_id,
            NEW.medicine_id,
            CONCAT(
                'LOW STOCK ALERT: "', m.name,
                '" at "', p.name,
                '" — Only ', NEW.quantity,
                ' units left (Threshold: ', NEW.threshold, ')'
            )
        FROM Medicine m, Pharmacy p
        WHERE m.medicine_id = NEW.medicine_id
          AND p.pharmacy_id = NEW.pharmacy_id;
    END IF;
END$$

DELIMITER ;

-- ============================================================
-- VIEW: Available medicines (quantity > 0)
-- ============================================================
CREATE OR REPLACE VIEW available_medicines AS
SELECT
    p.pharmacy_id,
    p.name          AS pharmacy_name,
    p.area,
    p.contact,
    m.medicine_id,
    m.name          AS medicine_name,
    m.category,
    m.life_saving,
    s.quantity,
    s.threshold,
    CASE WHEN s.quantity < s.threshold THEN 'LOW' ELSE 'OK' END AS stock_status
FROM Stock s
JOIN Pharmacy p ON p.pharmacy_id = s.pharmacy_id
JOIN Medicine m ON m.medicine_id = s.medicine_id
WHERE s.quantity > 0;

-- ============================================================
-- STORED PROCEDURE: Update stock quantity
-- ============================================================
DELIMITER $$

CREATE PROCEDURE update_stock(
    IN p_pharmacy_id INT,
    IN p_medicine_id INT,
    IN p_quantity    INT,
    IN p_threshold   INT
)
BEGIN
    -- Insert if not exists, update if exists
    INSERT INTO Stock (pharmacy_id, medicine_id, quantity, threshold)
    VALUES (p_pharmacy_id, p_medicine_id, p_quantity, p_threshold)
    ON DUPLICATE KEY UPDATE
        quantity  = p_quantity,
        threshold = p_threshold;
END$$

DELIMITER ;

-- ============================================================
-- SAMPLE DATA
-- ============================================================

INSERT INTO Pharmacy (name, area, contact) VALUES
('Apollo Pharmacy',        'Sector 17',    '9876543210'),
('MedPlus Health Store',   'Model Town',   '9876543211'),
('Jan Aushadhi Kendra',    'Urban Estate', '9876543212'),
('CityMed Pharmacy',       'Rajpura Road', '9876543213');

INSERT INTO Medicine (name, category, life_saving) VALUES
('Paracetamol 500mg',      'Analgesic',      0),
('Metformin 500mg',        'Anti-Diabetic',  0),
('Amlodipine 5mg',         'Anti-Hypertensive', 1),
('Amoxicillin 250mg',      'Antibiotic',     0),
('Aspirin 75mg',           'Antiplatelet',   1),
('Insulin Glargine',       'Anti-Diabetic',  1),
('Salbutamol Inhaler',     'Bronchodilator', 1),
('Omeprazole 20mg',        'Antacid',        0);

-- Stock entries (some will be low to trigger alerts)
CALL update_stock(1, 1, 200, 50);
CALL update_stock(1, 2, 30,  20);
CALL update_stock(1, 3, 8,   15);   -- LOW → triggers alert
CALL update_stock(1, 5, 5,   10);   -- LOW → triggers alert
CALL update_stock(2, 1, 100, 50);
CALL update_stock(2, 4, 60,  20);
CALL update_stock(2, 6, 3,   10);   -- LOW → triggers alert
CALL update_stock(3, 2, 45,  20);
CALL update_stock(3, 7, 12,  10);
CALL update_stock(3, 8, 90,  30);
CALL update_stock(4, 1, 50,  50);   -- exactly at threshold
CALL update_stock(4, 3, 25,  15);
CALL update_stock(4, 5, 70,  10);