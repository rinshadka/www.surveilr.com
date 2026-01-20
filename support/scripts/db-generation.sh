#!/usr/bin/env bash
set -Eeuo pipefail

trap '
echo "❌ ERROR"
echo "Line    : $LINENO"
echo "Command : $BASH_COMMAND"
echo "Path    : $(pwd)"
exit 1
' ERR

# --------------------------------------------------
# Global paths (override-safe)
# --------------------------------------------------
APP_DIR="${APP_DIR:-/app}"
REPO_DIR="$APP_DIR/www.surveilr.com"

RSSD_DIR="${RSSD_DIR:-/rssd}"
LOG_DIR="$RSSD_DIR/logs"

echo "===== SURVEILR PIPELINE STARTED ====="

# --------------------------------------------------
# Validate required ENV (runtime, not build-time)
# --------------------------------------------------
: "${EG_SURVEILR_COM_IMAP_FOLDER:?Missing IMAP folder}"
: "${EG_SURVEILR_COM_IMAP_USER_NAME:?Missing IMAP username}"
: "${EG_SURVEILR_COM_IMAP_PASS:?Missing IMAP password}"
: "${EG_SURVEILR_COM_IMAP_HOST:?Missing IMAP host}"

# --------------------------------------------------
# Prepare directories (CI-safe)
# --------------------------------------------------
rm -rf "$APP_DIR" "$RSSD_DIR"
mkdir -p "$APP_DIR" "$RSSD_DIR" "$LOG_DIR"

# --------------------------------------------------
# Clone repository
# --------------------------------------------------
cd "$APP_DIR"
git clone https://github.com/surveilr/www.surveilr.com.git

# --------------------------------------------------
# index.tsv (create once)
# --------------------------------------------------
cat > "$RSSD_DIR/index.tsv" <<EOF
expose_endpoint	relative_path	rssd_name	port	package_sql
EOF

# ==================================================
# PREPARE PHASE
# ==================================================
echo "▶ Running prepare scripts"

mapfile -t PREPARE_PATHS < <(
  find "$REPO_DIR" -type f -name 'eg.surveilr.com-prepare.ts' -exec dirname {} \;
)

for path in "${PREPARE_PATHS[@]}"; do
  relative_path="${path#$REPO_DIR/}"
  rssd_name="$(echo "$relative_path" | tr '/' '-').sqlite.db"
  base="$(basename "$relative_path")"

  echo "→ Prepare: $relative_path"
  cd "$path"

  if [[ "$base" == "site-quality-explorer" ]]; then
    deno run -A ./eg.surveilr.com-prepare.ts \
      resourceName=surveilr.com \
      rssdPath="$RSSD_DIR/$rssd_name" \
      > "$LOG_DIR/$rssd_name.log" 2>&1

  elif [[ "$base" == "content-assembler" ]]; then
    cat > .env <<EOF
IMAP_FOLDER=$EG_SURVEILR_COM_IMAP_FOLDER
IMAP_USER_NAME=$EG_SURVEILR_COM_IMAP_USER_NAME
IMAP_PASS=$EG_SURVEILR_COM_IMAP_PASS
IMAP_HOST=$EG_SURVEILR_COM_IMAP_HOST
EOF

    deno run -A ./eg.surveilr.com-prepare.ts \
      rssdPath="$RSSD_DIR/$rssd_name" \
      > "$LOG_DIR/$rssd_name.log" 2>&1 || {
        echo "❌ Content Assembler failed"
        cat "$LOG_DIR/$rssd_name.log"
        exit 1
      }

  else
    deno run -A ./eg.surveilr.com-prepare.ts \
      rssdPath="$RSSD_DIR/$rssd_name" \
      > "$LOG_DIR/$rssd_name.log" 2>&1
  fi
done

# ==================================================
# FINAL PHASE
# ==================================================
echo "▶ Running final scripts"

mapfile -t FINAL_PATHS < <(
  find "$REPO_DIR" -type f -name 'eg.surveilr.com-final.ts' -exec dirname {} \;
)

for path in "${FINAL_PATHS[@]}"; do
  if [[ "$(basename "$path")" == "direct-messaging-service" ]]; then
    cd "$path"
    deno run -A ./eg.surveilr.com-final.ts \
      destFolder="$RSSD_DIR/" \
      > "$LOG_DIR/direct-messaging-final.log" 2>&1
  fi
done

# ==================================================
# PACKAGE.SQL.TS PHASE
# ==================================================
echo "▶ Running package.sql.ts"

port=9000

mapfile -t PKG_PATHS < <(
  find "$REPO_DIR" -type f -name 'package.sql.ts' -exec dirname {} \;
)

for path in "${PKG_PATHS[@]}"; do
  relative_path="${path#$REPO_DIR/}"
  rssd_name="$(echo "$relative_path" | tr '/' '-').sqlite.db"

  echo "→ Package: $relative_path (port $port)"

  cd "$path"
  chmod +x package.sql.ts

  surveilr shell ./package.sql.ts \
    -d "$RSSD_DIR/$rssd_name" \
    >> "$LOG_DIR/$rssd_name.log" 2>&1

  echo -e "1\t$relative_path\t$rssd_name\t$port\t$relative_path/package.sql.ts" \
    >> "$RSSD_DIR/index.tsv"

  port=$((port + 1))
done

# ==================================================
# QUALITYFOLIO
# ==================================================
echo "▶ Copying qualityfolio package.sql"

mkdir -p "$RSSD_DIR/lib/service/qualityfolio"
cp "$REPO_DIR/lib/service/qualityfolio/package.sql" \
   "$RSSD_DIR/lib/service/qualityfolio/" 2>/dev/null || true

echo "===== SURVEILR PIPELINE COMPLETED SUCCESSFULLY ====="
