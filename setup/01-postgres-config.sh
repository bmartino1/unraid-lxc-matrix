#!/bin/bash
###############################################################################
# SETUP PHASE 01
# Configure PostgreSQL for Matrix Synapse
#
# - Installs PostgreSQL if missing
# - Starts/enables service
# - Creates synapse role
# - Creates synapse database with correct locale
# - Adds pg_hba authentication rules
# - Safe to run multiple times
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  postgres-config"
echo "══════════════════════════════════════════════════"
echo

###############################################################################
# Install PostgreSQL if missing
###############################################################################

if ! command -v psql >/dev/null 2>&1; then
  echo "  Installing PostgreSQL..."
  apt-get update
  apt-get install -y postgresql postgresql-contrib
fi

###############################################################################
# Start PostgreSQL
###############################################################################

echo "  Starting PostgreSQL..."
systemctl enable postgresql
systemctl start postgresql

###############################################################################
# Wait for service
###############################################################################

echo "  Waiting for PostgreSQL to be ready..."

for i in $(seq 1 30); do
  if pg_isready -U postgres -q; then
    break
  fi
  sleep 2
done

if ! pg_isready -U postgres -q; then
  echo "ERROR: PostgreSQL did not start"
  exit 1
fi

###############################################################################
# Detect correct locale
###############################################################################

echo "  Detecting locale..."

if locale -a | grep -q "^C\.utf8$"; then
  DB_LOCALE="C.utf8"
else
  DB_LOCALE="C"
fi

echo "  Using locale: ${DB_LOCALE}"

###############################################################################
# Create synapse role
###############################################################################

echo "  Ensuring synapse role exists..."

sudo -u postgres psql <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_roles WHERE rolname = 'synapse'
   ) THEN
      CREATE ROLE synapse LOGIN PASSWORD '${POSTGRES_PASS}';
   ELSE
      ALTER ROLE synapse WITH PASSWORD '${POSTGRES_PASS}';
   END IF;
END
\$\$;
SQL

###############################################################################
# Create synapse database
###############################################################################

echo "  Ensuring synapse database exists..."

DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='synapse'")

if [ "${DB_EXISTS}" != "1" ]; then
  sudo -u postgres createdb \
    --encoding=UTF8 \
    --lc-collate="${DB_LOCALE}" \
    --lc-ctype="${DB_LOCALE}" \
    --template=template0 \
    --owner=synapse \
    synapse

  echo "  Database created."
else
  echo "  Database already exists."
fi

###############################################################################
# Configure pg_hba.conf
###############################################################################

PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file")

echo "  Configuring pg_hba.conf (${PG_HBA})..."

if ! grep -q "Matrix Synapse - added by setup.sh" "${PG_HBA}"; then
  cat >> "${PG_HBA}" <<EOF

# Matrix Synapse - added by setup.sh
local   synapse         synapse                                 md5
host    synapse         synapse         127.0.0.1/32            md5
host    synapse         synapse         ::1/128                 md5
EOF
fi

###############################################################################
# Reload PostgreSQL
###############################################################################

systemctl reload postgresql

echo
echo "  PostgreSQL configured successfully."
echo
