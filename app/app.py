"""Minimal Flask app backing onto PostgreSQL.

Records a row per request so database persistence across container
restarts can be demonstrated rather than asserted.
"""
import os
import socket
import time
from datetime import datetime, timezone

import psycopg2
from flask import Flask, jsonify, render_template_string

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "db")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("POSTGRES_DB", "appdb")
DB_USER = os.environ.get("POSTGRES_USER", "appuser")
DB_PASS = os.environ.get("POSTGRES_PASSWORD", "")

PAGE = """<!doctype html>
<title>Infra Assignment</title>
<style>
  body { font-family: system-ui, sans-serif; background:#0f172a; color:#e2e8f0;
         display:flex; min-height:100vh; align-items:center; justify-content:center; margin:0 }
  .card { background:#1e293b; padding:2.5rem 3rem; border-radius:12px;
          border:1px solid #334155; max-width:34rem }
  h1 { margin:0 0 .25rem; font-size:1.4rem }
  .sub { color:#94a3b8; font-size:.85rem; margin-bottom:1.5rem }
  dl { display:grid; grid-template-columns:auto 1fr; gap:.6rem 1.5rem; margin:0; font-size:.9rem }
  dt { color:#94a3b8 } dd { margin:0; font-family:ui-monospace,monospace; color:#7dd3fc }
  .ok { color:#4ade80 }
</style>
<div class="card">
  <h1>Reverse-proxied application</h1>
  <div class="sub">Request arrived via nginx on port 80 &rarr; app on internal port 5000</div>
  <dl>
    <dt>Served by container</dt><dd>{{ host }}</dd>
    <dt>Database</dt><dd class="ok">connected</dd>
    <dt>Visits recorded</dt><dd>{{ total }}</dd>
    <dt>First visit stored</dt><dd>{{ first }}</dd>
    <dt>Server time</dt><dd>{{ now }}</dd>
  </dl>
</div>
"""


def connect():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS, connect_timeout=5,
    )


def init_db(retries=30, delay=2):
    """Create the schema, retrying while PostgreSQL finishes starting."""
    last = None
    for attempt in range(1, retries + 1):
        try:
            conn = connect()
            with conn, conn.cursor() as cur:
                cur.execute(
                    "CREATE TABLE IF NOT EXISTS visits ("
                    "  id SERIAL PRIMARY KEY,"
                    "  seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),"
                    "  served_by TEXT NOT NULL)"
                )
            conn.close()
            print(f"[init] schema ready after {attempt} attempt(s)", flush=True)
            return
        except psycopg2.OperationalError as exc:
            last = exc
            print(f"[init] database not ready ({attempt}/{retries})", flush=True)
            time.sleep(delay)
    raise RuntimeError(f"database unreachable after {retries} attempts: {last}")


init_db()


@app.route("/")
def index():
    host = socket.gethostname()
    conn = connect()
    with conn, conn.cursor() as cur:
        cur.execute("INSERT INTO visits (served_by) VALUES (%s)", (host,))
        cur.execute("SELECT count(*) FROM visits")
        total = cur.fetchone()[0]
        cur.execute("SELECT seen_at FROM visits ORDER BY id ASC LIMIT 1")
        first = cur.fetchone()[0]
    conn.close()
    return render_template_string(
        PAGE, host=host, total=total,
        first=first.strftime("%Y-%m-%d %H:%M:%S UTC"),
        now=datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
    )


@app.route("/healthz")
def healthz():
    try:
        conn = connect()
        with conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        conn.close()
        return jsonify(status="ok", database="up"), 200
    except Exception as exc:
        return jsonify(status="degraded", database="down", error=str(exc)), 503
