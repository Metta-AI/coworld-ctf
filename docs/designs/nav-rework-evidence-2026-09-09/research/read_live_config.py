"""Read only the configuration fields needed to validate the benchmark shape."""
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import psycopg
from psycopg.rows import dict_row

out = Path(__file__).with_name("LIVE_CONFIG_DIAGNOSTIC.json")
result = {"observed_at": datetime.now(timezone.utc).isoformat()}
try:
    with psycopg.connect(os.environ["OBSERVATORY_DB_URI"], connect_timeout=15,
                         options="-c default_transaction_read_only=on -c statement_timeout=15000",
                         row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT coworld_id, name, version, canonical, created_at,
                  (SELECT v->'game_config'->>'gunRange'
                   FROM jsonb_array_elements(manifest->'variants') v
                   WHERE v->>'id'='battle-royale-s2') AS gun_range,
                  (SELECT v->'game_config'->>'mapPath'
                   FROM jsonb_array_elements(manifest->'variants') v
                   WHERE v->>'id'='battle-royale-s2') AS map_path
                FROM coworlds WHERE name='paintbot' AND canonical
                ORDER BY created_at DESC LIMIT 5
            """)
            result["coworlds"] = cur.fetchall()
            ids = [row["coworld_id"] for row in result["coworlds"]]
            cur.execute("""
                SELECT episode_request_id, coworld_id, created_at, variant_id,
                  (round_id IS NOT NULL) AS league_episode,
                  game_config->>'gunRange' AS gun_range,
                  game_config->>'mapPath' AS map_path,
                  game_config->>'teams' AS teams
                FROM episode_requests
                WHERE coworld_id=ANY(%s) AND variant_id='battle-royale-s2'
                  AND created_at >= now() - interval '12 hours'
                ORDER BY created_at DESC LIMIT 30
            """, (ids,))
            result["episodes"] = cur.fetchall()
    result["status"] = "ok"
except Exception as error:
    # Connection errors can contain credentials; do not print their message.
    result["status"] = "error"
    result["error_type"] = type(error).__name__
    result["sqlstate"] = getattr(error, "sqlstate", None)
    message = str(error).lower()
    result["category"] = next((label for label, token in [
        ("timeout", "timeout"), ("dns", "translate host"),
        ("connection_refused", "connection refused"),
        ("authentication", "authentication"), ("ssl", "ssl")]
        if token in message), "unclassified")
out.write_text(json.dumps(result, default=str, indent=2) + "\n")
print(json.dumps(result, default=str))
raise SystemExit(0 if result["status"] == "ok" else 1)
