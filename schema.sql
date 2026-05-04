-- ============================================================
-- Community Medicine Availability & Shortage Alert System
-- MySQL Schema
-- ============================================================

CREATE DATABASE IF NOT EXISTS medicine_db;
USE medicine_db;

CREATE TABLE IF NOT EXISTS Pharmacy (
    pharmacy_id INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(150) NOT NULL,
    area        VARCHAR(100) NOT NULL,
    contact     VARCHAR(20)  NOT NULL
);

CREATE TABLE IF NOT EXISTS Medicine (
    medicine_id  INT AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    category     VARCHAR(100) NOT NULL,
    life_saving  TINYINT(1)   NOT NULL DEFAULT 0  -- 1 = Yes, 0 = No
);

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

CREATE TABLE IF NOT EXISTS Alert (
    alert_id    INT AUTO_INCREMENT PRIMARY KEY,
    pharmacy_id INT  NOT NULL,
    medicine_id INT  NOT NULL,
    message     TEXT NOT NULL,
    alert_date  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_alert_pharmacy FOREIGN KEY (pharmacy_id) REFERENCES Pharmacy(pharmacy_id) ON DELETE CASCADE,
    CONSTRAINT fk_alert_medicine FOREIGN KEY (medicine_id) REFERENCES Medicine(medicine_id) ON DELETE CASCADE
);

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
-- FUNCTION: Get stock status label for a given quantity/threshold
-- ============================================================
DELIMITER $$

CREATE FUNCTION get_stock_status(p_quantity INT, p_threshold INT)
RETURNS VARCHAR(20)
DETERMINISTIC
BEGIN
    DECLARE status VARCHAR(20);
    IF p_quantity = 0 THEN
        SET status = 'OUT OF STOCK';
    ELSEIF p_quantity < p_threshold THEN
        SET status = 'LOW STOCK';
    ELSEIF p_quantity <= p_threshold * 1.5 THEN
        SET status = 'ADEQUATE';
    ELSE
        SET status = 'SUFFICIENT';
    END IF;
    RETURN status;
END$$

DELIMITER ;

-- ============================================================
-- FUNCTION: Check if a medicine is available in any pharmacy
-- ============================================================
DELIMITER $$

CREATE FUNCTION is_medicine_available(p_medicine_id INT)
RETURNS VARCHAR(3)
DETERMINISTIC
BEGIN
    DECLARE total_qty INT DEFAULT 0;
    SELECT COALESCE(SUM(quantity), 0)
    INTO   total_qty
    FROM   Stock
    WHERE  medicine_id = p_medicine_id;

    IF total_qty > 0 THEN
        RETURN 'YES';
    ELSE
        RETURN 'NO';
    END IF;
END$$

DELIMITER ;

-- ============================================================
-- STORED PROCEDURE WITH CURSOR: Generate low-stock report
-- Iterates through all low-stock entries and prints a report
-- ============================================================
DELIMITER $$

CREATE PROCEDURE generate_low_stock_report()
BEGIN
    -- Cursor variables
    DECLARE v_pharmacy_name  VARCHAR(150);
    DECLARE v_medicine_name  VARCHAR(150);
    DECLARE v_quantity        INT;
    DECLARE v_threshold       INT;
    DECLARE v_life_saving     TINYINT(1);
    DECLARE done              INT DEFAULT FALSE;

    -- Declare cursor for all low-stock entries
    DECLARE low_stock_cursor CURSOR FOR
        SELECT
            p.name      AS pharmacy_name,
            m.name      AS medicine_name,
            s.quantity,
            s.threshold,
            m.life_saving
        FROM  Stock s
        JOIN  Pharmacy p ON p.pharmacy_id = s.pharmacy_id
        JOIN  Medicine m ON m.medicine_id = s.medicine_id
        WHERE s.quantity < s.threshold
        ORDER BY m.life_saving DESC, s.quantity ASC;

    -- Handler for end of cursor
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    -- Open cursor and iterate
    OPEN low_stock_cursor;

    read_loop: LOOP
        FETCH low_stock_cursor
        INTO  v_pharmacy_name, v_medicine_name,
              v_quantity, v_threshold, v_life_saving;

        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Output each low-stock record as a report line
        SELECT
            CONCAT(
                IF(v_life_saving = 1, '[CRITICAL] ', '[WARNING]  '),
                v_pharmacy_name, ' | ',
                v_medicine_name, ' | Qty: ',
                v_quantity, ' / Threshold: ', v_threshold,
                ' | Status: ', get_stock_status(v_quantity, v_threshold)
            ) AS low_stock_report;

    END LOOP;

    CLOSE low_stock_cursor;
END$$

DELIMITER ;

-- ============================================================
-- STORED PROCEDURE WITH CURSOR: Auto-insert alerts for all
-- existing low-stock entries (useful on first load / resync)
-- ============================================================
DELIMITER $$

CREATE PROCEDURE sync_alerts_for_low_stock()
BEGIN
    DECLARE v_pharmacy_id INT;
    DECLARE v_medicine_id INT;
    DECLARE v_quantity     INT;
    DECLARE v_threshold    INT;
    DECLARE done           INT DEFAULT FALSE;

    DECLARE sync_cursor CURSOR FOR
        SELECT pharmacy_id, medicine_id, quantity, threshold
        FROM   Stock
        WHERE  quantity < threshold;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    OPEN sync_cursor;

    sync_loop: LOOP
        FETCH sync_cursor
        INTO  v_pharmacy_id, v_medicine_id, v_quantity, v_threshold;

        IF done THEN
            LEAVE sync_loop;
        END IF;

        INSERT INTO Alert (pharmacy_id, medicine_id, message)
        SELECT
            v_pharmacy_id,
            v_medicine_id,
            CONCAT(
                'SYNC ALERT: "', m.name,
                '" at "', p.name,
                '" — Only ', v_quantity,
                ' units left (Threshold: ', v_threshold, ')'
            )
        FROM Medicine m, Pharmacy p
        WHERE m.medicine_id = v_medicine_id
          AND p.pharmacy_id = v_pharmacy_id;

    END LOOP;

    CLOSE sync_cursor;
END$$

DELIMITER ;

-- ============================================================
-- STORED PROCEDURE WITH EXCEPTION HANDLING:
-- Safe stock update wrapped in transaction with error handling
-- ============================================================
DELIMITER $$

CREATE PROCEDURE safe_update_stock(
    IN  p_pharmacy_id  INT,
    IN  p_medicine_id  INT,
    IN  p_quantity     INT,
    IN  p_threshold    INT,
    OUT p_result       VARCHAR(100)
)
BEGIN
    -- Exit handler: on any SQL error, rollback and set error message
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_result = 'ERROR: Stock update failed. Transaction rolled back.';
    END;

    -- Validate inputs before touching the DB
    IF p_quantity < 0 THEN
        SET p_result = 'ERROR: Quantity cannot be negative.';
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Quantity cannot be negative.';
    END IF;

    IF p_threshold <= 0 THEN
        SET p_result = 'ERROR: Threshold must be greater than zero.';
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Threshold must be greater than zero.';
    END IF;

    -- Begin transaction
    START TRANSACTION;

        -- Upsert stock (trigger fires automatically if qty < threshold)
        INSERT INTO Stock (pharmacy_id, medicine_id, quantity, threshold)
        VALUES (p_pharmacy_id, p_medicine_id, p_quantity, p_threshold)
        ON DUPLICATE KEY UPDATE
            quantity  = p_quantity,
            threshold = p_threshold;

    COMMIT;

    SET p_result = CONCAT(
        'SUCCESS: Stock updated. Status = ',
        get_stock_status(p_quantity, p_threshold)
    );
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