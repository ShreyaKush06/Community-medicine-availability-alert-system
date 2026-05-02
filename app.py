"""
Community Medicine Availability & Shortage Alert System
Flask Backend – app.py
"""

import os
from flask import Flask, render_template, request, redirect, url_for, flash, make_response
import mysql.connector
from mysql.connector import Error
from dotenv import load_dotenv
from pathlib import Path
load_dotenv(dotenv_path=Path(__file__).parent / ".env")

app = Flask(__name__, static_folder='credentials/static')
app.secret_key = os.getenv("SECRET_KEY", "medicine_alert_secret_2024")

def get_db():
    return mysql.connector.connect(
        host     = "localhost",
        port     = 3306,
        user     = "root",
        password = "Shreya@OP1",  
        database = "medicine_db",
    )

def error_page(message):
    """Return a self-contained HTML error page without using a template."""
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Database Error</title>
  <style>
    body {{ font-family: sans-serif; background: #f4f6fa; display: flex;
            align-items: center; justify-content: center; min-height: 100vh; margin: 0; }}
    .box {{ background: #fff; border: 1px solid #e2e8f0; border-radius: 10px;
            padding: 2.5rem; max-width: 640px; width: 100%; box-shadow: 0 4px 12px rgba(0,0,0,.08); }}
    h2   {{ color: #1a202c; margin-bottom: .5rem; }}
    p    {{ color: #718096; margin-bottom: 1.2rem; font-size: .95rem; }}
    code {{ display: block; background: #fef2f2; color: #dc2626; padding: 1rem;
            border-radius: 8px; font-size: .85rem; word-break: break-all; white-space: pre-wrap; }}
    .tip {{ margin-top: 1.2rem; background: #eff6ff; color: #2563eb;
            padding: .9rem 1rem; border-radius: 8px; font-size: .88rem; }}
    a    {{ color: #2563eb; }}
  </style>
</head>
<body>
  <div class="box">
    <h2> Database Connection Error</h2>
    <p>Flask could not connect to MySQL. Check your <code>.env</code> file and make sure MySQL is running.</p>
    <code>{message}</code>
    <div class="tip">
      <strong>Fix checklist:</strong><br>
      1. Is MySQL running? (check Task Manager / Services)<br>
      2. Open <code>.env</code> — is <code>DB_PASSWORD</code> correct?<br>
      3. Does the database <code>medicine_db</code> exist? Run <code>mysql -u root -p &lt; schema.sql</code><br>
      4. Is <code>DB_USER=root</code> correct for your setup?
    </div>
    <p style="margin-top:1rem"><a href="/">← Try again</a></p>
  </div>
</body>
</html>"""
    return make_response(html, 500)


@app.route("/")
def index():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)

        # Summary stats for dashboard cards
        cur.execute("SELECT COUNT(*) AS total FROM Pharmacy")
        pharmacies = cur.fetchone()["total"]

        cur.execute("SELECT COUNT(*) AS total FROM Medicine")
        medicines = cur.fetchone()["total"]

        cur.execute("SELECT COUNT(*) AS total FROM Alert")
        alerts = cur.fetchone()["total"]

        cur.execute(
            "SELECT COUNT(*) AS total FROM Stock WHERE quantity < threshold"
        )
        low_stock = cur.fetchone()["total"]

        cur.close(); conn.close()
        return render_template(
            "index.html",
            pharmacies=pharmacies,
            medicines=medicines,
            alerts=alerts,
            low_stock=low_stock,
        )
    except Error as e:
        return error_page(str(e))


@app.route("/search", methods=["GET"])
def search():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)

        # Populate medicine dropdown
        cur.execute("SELECT medicine_id, name, category FROM Medicine ORDER BY name")
        medicines = cur.fetchall()

        # Populate area filter dropdown
        cur.execute("SELECT DISTINCT area FROM Pharmacy ORDER BY area")
        areas = [row["area"] for row in cur.fetchall()]

        results     = []
        query_name  = request.args.get("medicine_name", "").strip()
        query_area  = request.args.get("area", "").strip()
        searched    = False

        if query_name:
            searched = True
            sql = """
                SELECT
                    p.name          AS pharmacy_name,
                    p.area,
                    p.contact,
                    m.name          AS medicine_name,
                    m.category,
                    m.life_saving,
                    s.quantity,
                    s.threshold,
                    CASE WHEN s.quantity < s.threshold THEN 'LOW' ELSE 'OK'
                    END             AS stock_status
                FROM Stock s
                JOIN Pharmacy p ON p.pharmacy_id = s.pharmacy_id
                JOIN Medicine m ON m.medicine_id = s.medicine_id
                WHERE m.name LIKE %s
                  AND s.quantity > 0
            """
            params = [f"%{query_name}%"]

            if query_area:
                sql   += " AND p.area = %s"
                params.append(query_area)

            sql += " ORDER BY s.quantity DESC"
            cur.execute(sql, params)
            results = cur.fetchall()

        cur.close(); conn.close()
        return render_template(
            "search.html",
            medicines=medicines,
            areas=areas,
            results=results,
            searched=searched,
            query_name=query_name,
            query_area=query_area,
        )
    except Error as e:
        return error_page(str(e))


@app.route("/add_stock", methods=["GET", "POST"])
def add_stock():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)

        cur.execute("SELECT pharmacy_id, name, area FROM Pharmacy ORDER BY name")
        pharmacies = cur.fetchall()

        cur.execute("SELECT medicine_id, name, category FROM Medicine ORDER BY name")
        medicines = cur.fetchall()

        if request.method == "POST":
            pharmacy_id = int(request.form["pharmacy_id"])
            medicine_id = int(request.form["medicine_id"])
            quantity    = int(request.form["quantity"])
            threshold   = int(request.form["threshold"])

            if quantity < 0:
                flash("Quantity cannot be negative.", "error")
            elif threshold <= 0:
                flash("Threshold must be greater than zero.", "error")
            else:
                # Call stored procedure
                cur.callproc(
                    "update_stock",
                    [pharmacy_id, medicine_id, quantity, threshold],
                )
                conn.commit()
                flash("Stock updated successfully!", "success")
                cur.close(); conn.close()
                return redirect(url_for("add_stock"))

        # Recent stock table
        cur.execute("""
            SELECT
                p.name AS pharmacy_name, p.area,
                m.name AS medicine_name, m.category,
                s.quantity, s.threshold,
                CASE WHEN s.quantity < s.threshold THEN 'LOW' ELSE 'OK'
                END AS stock_status
            FROM Stock s
            JOIN Pharmacy p ON p.pharmacy_id = s.pharmacy_id
            JOIN Medicine m ON m.medicine_id = s.medicine_id
            ORDER BY s.stock_id DESC
            LIMIT 20
        """)
        recent = cur.fetchall()

        cur.close(); conn.close()
        return render_template(
            "add_stock.html",
            pharmacies=pharmacies,
            medicines=medicines,
            recent=recent,
        )
    except Error as e:
        return error_page(str(e))


@app.route("/alerts")
def alerts():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)

        filter_type = request.args.get("filter", "all")

        sql = """
            SELECT
                a.alert_id,
                p.name  AS pharmacy_name,
                p.area,
                m.name  AS medicine_name,
                m.life_saving,
                a.message,
                a.alert_date
            FROM Alert a
            JOIN Pharmacy p ON p.pharmacy_id = a.pharmacy_id
            JOIN Medicine m ON m.medicine_id = a.medicine_id
        """
        if filter_type == "critical":
            sql += " WHERE m.life_saving = 1"

        sql += " ORDER BY a.alert_date DESC"
        cur.execute(sql)
        alert_list = cur.fetchall()

        cur.execute("SELECT COUNT(*) AS cnt FROM Alert")
        total = cur.fetchone()["cnt"]

        cur.execute(
            "SELECT COUNT(*) AS cnt FROM Alert a "
            "JOIN Medicine m ON m.medicine_id = a.medicine_id WHERE m.life_saving = 1"
        )
        critical = cur.fetchone()["cnt"]

        cur.close(); conn.close()
        return render_template(
            "alerts.html",
            alert_list=alert_list,
            filter_type=filter_type,
            total=total,
            critical=critical,
        )
    except Error as e:
        return error_page(str(e))


@app.route("/available")
def available():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM available_medicines ORDER BY medicine_name, area")
        rows = cur.fetchall()
        cur.close(); conn.close()
        return render_template("available.html", rows=rows)
    except Error as e:
        return error_page(str(e))


if __name__ == "__main__":
    print("\n🔍 Testing MySQL connection...")
    try:
        test = get_db()
        test.close()
        print("✅ MySQL connected successfully!\n")
    except Error as e:
        print(f"\n MySQL connection FAILED: {e}")
        print("   → Check DB_HOST, DB_USER, DB_PASSWORD, DB_NAME in your .env file")
        print("   → Make sure MySQL service is running\n")

    port = int(os.getenv("PORT", 5000))
    app.run(debug=os.getenv("FLASK_DEBUG", "true").lower() == "true", port=port)