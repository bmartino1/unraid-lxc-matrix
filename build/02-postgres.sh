#!/bin/bash
# Stage 02 - PostgreSQL 16 install and database setup for Matrix Synapse
set -euo pipefail

echo "==> Installing PostgreSQL 16..."
export DEBIAN_FRONTEND=noninteractive
apt-get -y install postgresql-16 postgresql-client-16

echo "==> Starting PostgreSQL service..."
systemctl enable postgresql
systemctl start postgresql

echo "==> Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
  if pg_isready -U postgres -q; then
    echo "   PostgreSQL is ready."
    break
  fi
  echo "   Waiting... ($i/30)"
  sleep 2
done

echo "==> Creating synapse user and database..."
sudo -u postgres psql <<SQL
-- Create synapse role with login
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'synapse') THEN
    CREATE ROLE synapse WITH LOGIN PASSWORD '${POSTGRES_PASS}';
  ELSE
    ALTER ROLE synapse WITH PASSWORD '${POSTGRES_PASS}';
  END IF;
END
\$\$;

-- Create synapse database with required locale settings
SELECT 'CREATE DATABASE synapse
  ENCODING UTF8
  LC_COLLATE C
  LC_CTYPE C
  TEMPLATE template0
  OWNER synapse'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'synapse')\gexec
SQL

echo "==> Configuring PostgreSQL to allow synapse user connections..."
PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
# Add local trust for synapse if not already there
if ! grep -q "synapse" "$PG_HBA"; then
  echo "local   synapse         synapse                                 md5" >> "$PG_HBA"
  echo "host    synapse         synapse         127.0.0.1/32            md5" >> "$PG_HBA"
fi

systemctl reload postgresql

echo "==> Saving PostgreSQL connection string..."
cat > /etc/matrix-synapse/db.env <<EOF
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DB=synapse
POSTGRES_USER=synapse
POSTGRES_PASS=${POSTGRES_PASS}
EOF
chmod 640 /etc/matrix-synapse/db.env || true

echo "Completed Stage 02 - PostgreSQL"
