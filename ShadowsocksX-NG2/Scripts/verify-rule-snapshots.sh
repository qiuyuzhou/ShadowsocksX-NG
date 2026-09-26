#!/usr/bin/env bash
# Build-time offline verification of pinned rule snapshots (issue #63).
# Ordinary builds never fetch or convert; they only verify the local snapshot
# is present, intact, and matches its manifest. Missing, corrupt, or
# version-mismatched snapshots fail the build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES_DIR="${ROOT}/Vendor/rules/geolocation-cn"
SNAPSHOT="${RULES_DIR}/snapshot.json"
MANIFEST="${RULES_DIR}/manifest.json"
NOTICE="${RULES_DIR}/NOTICE"

fail() {
  echo "error: $*" >&2
  echo "  (run Scripts/update-geolocation-cn.sh after reviewing upstream changes)" >&2
  exit 1
}

[[ -f "${SNAPSHOT}" ]] || fail "missing ${SNAPSHOT}"
[[ -f "${MANIFEST}" ]] || fail "missing ${MANIFEST}"
[[ -f "${NOTICE}" ]] || fail "missing ${NOTICE} (license/attribution must ship with the snapshot)"

python3 - "${SNAPSHOT}" "${MANIFEST}" <<'PY' || fail "rule snapshot verification failed"
import hashlib, json, sys
from pathlib import Path

snapshot_path, manifest_path = sys.argv[1], sys.argv[2]
snapshot_bytes = Path(snapshot_path).read_bytes()
try:
    snapshot = json.loads(snapshot_bytes)
except Exception as exc:  # noqa: BLE001
    raise SystemExit(f"snapshot is not valid JSON: {exc}")

if snapshot.get("schemaVersion") != 1:
    raise SystemExit(f"schemaVersion mismatch: {snapshot.get('schemaVersion')!r} != 1")

meta = snapshot.get("metadata") or {}
for key in ("source", "upstreamReference", "inputDigest", "fetchedAt", "converterVersion", "license", "attribution"):
    if key not in meta:
        raise SystemExit(f"snapshot metadata missing {key!r}")

if meta.get("converterVersion") != "1.0.0":
    raise SystemExit(
        f"converterVersion mismatch: {meta.get('converterVersion')!r} != '1.0.0' "
        "(re-run the explicit update or bump both sides together)"
    )

rules = snapshot.get("rules")
if not isinstance(rules, list) or not rules:
    raise SystemExit("snapshot has no rules")
if len(rules) < 100 or len(rules) > 200_000:
    raise SystemExit(f"abnormal rule count {len(rules)}")

try:
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
except Exception as exc:  # noqa: BLE001
    raise SystemExit(f"manifest is not valid JSON: {exc}")

for key in ("upstreamVersion", "snapshotSHA256", "converterVersion"):
    if key not in manifest:
        raise SystemExit(f"manifest missing {key!r}")

if manifest.get("converterVersion") != meta.get("converterVersion"):
    raise SystemExit("manifest converterVersion does not match snapshot metadata")

digest = hashlib.sha256(snapshot_bytes).hexdigest()
if digest != manifest.get("snapshotSHA256"):
    raise SystemExit(
        "snapshot SHA-256 does not match manifest "
        f"({digest} != {manifest.get('snapshotSHA256')})"
    )

if manifest.get("upstreamVersion") != meta.get("source", {}).get("upstreamVersion"):
    raise SystemExit("manifest upstreamVersion does not match snapshot metadata")

print(f"rule snapshot ok: {len(rules)} rules, upstream {meta.get('upstreamVersion')}")
PY

echo "verify-rule-snapshots: ok"
