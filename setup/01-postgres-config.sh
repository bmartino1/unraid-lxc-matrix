#!/bin/bash
set -euo pipefail
echo "  Configuring PostgreSQL..."

systemctl enable postgresql
systemctl start postgresql

for i in $(seq 1 30); do pg_isready -U postgres -q && break; sleep 2; done
pg_isready -U postgres -q || { echo "ERROR: PostgreSQL failed"; exit 1; }

sudo -u postgres psql <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'synapse_user') THEN
      CREATE ROLE synapse_user LOGIN PASSWORD '${POSTGRES_PASSWORD}';
   ELSE
      ALTER ROLE synapse_user WITH PASSWORD '${POSTGRES_PASSWORD}';
   END IF;
END
\$\$;
SQL

DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='synapse'")
if [ "${DB_EXISTS}" != "1" ]; then
  sudo -u postgres createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C \
    --template=template0 --owner=synapse_user synapse
  echo "  Database created."
fi

PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file")
if ! grep -q "synapse_user" "${PG_HBA}" 2>/dev/null; then
  cat >> "${PG_HBA}" <<HBAEOF

# Matrix Synapse
host    synapse         synapse_user    127.0.0.1/32            scram-sha-256
host    synapse         synapse_user    ::1/128                 scram-sha-256
HBAEOF
fi
systemctl reload postgresql
echo "  PostgreSQL configured."
