#!/bin/bash
# SETUP PHASE - 01: Configure PostgreSQL
# Creates the synapse DB user and database with correct locale settings
set -euo pipefail

echo "  Starting PostgreSQL..."
systemctl start postgresql
systemctl enable postgresql

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
  pg_isready -U postgres -q && break
  sleep 2
done
pg_isready -U postgres -q || { echo "ERROR: PostgreSQL did not start"; exit 1; }

echo "  Creating synapse database user and database..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'synapse') THEN
    CREATE ROLE synapse WITH LOGIN PASSWORD '${POSTGRES_PASS}';
  ELSE
    ALTER ROLE synapse WITH PASSWORD '${POSTGRES_PASS}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE synapse
  ENCODING UTF8
  LC_COLLATE 'C.utf8'
  LC_CTYPE 'C.utf8'
  TEMPLATE template0
  OWNER synapse'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'synapse')\gexec
SQL

echo "  Configuring pg_hba.conf for synapse user..."
PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
if ! grep -q "synapse" "${PG_HBA}"; then
  cat >> "${PG_HBA}" <<EOF

# Matrix Synapse - added by setup.sh
local   synapse         synapse                                 md5
host    synapse         synapse         127.0.0.1/32            md5
host    synapse         synapse         ::1/128                 md5
EOF
fi

systemctl reload postgresql
echo "  PostgreSQL configured."
