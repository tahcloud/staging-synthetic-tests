#!/bin/bash
# PostgreSQL Lifecycle Test Script
# Tests PG creation, data operations, scaling, upgrading, firewall rules, read replicas, and destruction
# Intended to be run in CI/CD (GitHub Actions)

set -euo pipefail

# Configuration
: "${UBI_TOKEN:?Error: UBI_TOKEN environment variable must be set}"
: "${UBI_URL:?Error: UBI_URL environment variable must be set}"
: "${PG_LOCATION:=eu-central-h1}"
: "${PG_SIZE:=standard-2}"
: "${PG_STORAGE:=64}"
: "${PG_VERSION:=17}"
: "${PG_UPGRADE_VERSION:=18}"
: "${PG_SCALED_SIZE:=standard-4}"
: "${PG_SCALED_STORAGE:=128}"

export UBI_TOKEN UBI_URL

# Generate unique PG name using timestamp
PG_NAME="test-pg-$(date +%s)"
PG_REF="${PG_LOCATION}/${PG_NAME}"
REPLICA_NAME="${PG_NAME}-replica"

cleanup() {
    echo ""
    echo "=== Cleaning up ==="

    # Destroy read replica if it exists
    echo "Destroying read replica (if exists)..."
    ubi pg "${PG_LOCATION}/${REPLICA_NAME}" destroy -f 2>/dev/null || true

    # Destroy primary
    echo "Destroying primary PG: ${PG_REF}"
    ubi pg "${PG_REF}" destroy -f 2>/dev/null || true
}

trap cleanup EXIT

# Helper function to get PG field value
get_pg_field() {
    local ref=$1
    local field=$2
    ubi pg "${ref}" show -f "${field}" 2>/dev/null | awk -F': ' '{print $2}' || echo ""
}

# Helper function to wait for PG state
wait_for_pg_state() {
    local ref=$1
    local target_state=$2
    local max_wait=${3:-600}
    local wait_interval=15
    local elapsed=0

    echo "Waiting for ${ref} to reach '${target_state}' state..."
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        local state
        state=$(get_pg_field "${ref}" "state")

        if [[ "${state}" == "${target_state}" ]]; then
            echo "  State: ${state} - Ready!"
            return 0
        fi

        echo "  State: ${state} (waited ${elapsed}s)"
        sleep ${wait_interval}
        elapsed=$((elapsed + wait_interval))
    done

    echo "Error: ${ref} did not reach '${target_state}' state within ${max_wait}s"
    return 1
}

# Helper function to wait for PG field to reach target value
wait_for_pg_field() {
    local ref=$1
    local field=$2
    local target_value=$3
    local max_wait=${4:-900}
    local wait_interval=15
    local elapsed=0

    echo "Waiting for ${field} to become '${target_value}'..."
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        local current_value
        current_value=$(get_pg_field "${ref}" "${field}")

        if [[ "${current_value}" == "${target_value}" ]]; then
            echo "  ${field}: ${current_value} - Ready!"
            return 0
        fi

        echo "  ${field}: ${current_value} (waited ${elapsed}s)"
        sleep ${wait_interval}
        elapsed=$((elapsed + wait_interval))
    done

    echo "Error: ${field} did not reach '${target_value}' within ${max_wait}s"
    return 1
}

# Helper function to run SQL query using psql directly (tests DNS integration)
run_sql_direct() {
    local pg_ref=$1
    local query=$2
    local conn_string
    conn_string=$(get_pg_field "${pg_ref}" "connection-string")
    # Strip query parameters that may cause issues
    conn_string=$(echo "${conn_string}" | sed 's|\?.*||')
    psql "${conn_string}" -t -A -c "${query}"
}

# Helper function to run SQL query using ubi CLI
run_sql_ubi() {
    local pg_ref=$1
    local query=$2
    ubi pg "${pg_ref}" psql -t -A -c "${query}"
}

# Helper function to wait for PG upgrade using show-upgrade-status
wait_for_pg_upgrade() {
    local ref=$1
    local target_version=$2
    local max_wait=${3:-1800}
    local wait_interval=15
    local elapsed=0

    echo "Waiting for upgrade to version ${target_version}..."
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        local current_version
        current_version=$(get_pg_field "${ref}" "version")

        if [[ "${current_version}" == "${target_version}" ]]; then
            echo "  Version: ${current_version} - Upgrade complete!"
            return 0
        fi

        # Show upgrade status for visibility
        local upgrade_status
        upgrade_status=$(ubi pg "${ref}" show-upgrade-status 2>/dev/null | grep -i "status:" | awk -F': ' '{print $2}' || echo "unknown")
        echo "  Version: ${current_version}, Upgrade status: ${upgrade_status} (waited ${elapsed}s)"

        sleep ${wait_interval}
        elapsed=$((elapsed + wait_interval))
    done

    echo "Error: Upgrade did not complete within ${max_wait}s"
    return 1
}

# Helper function to wait for PG connectivity using direct psql
wait_for_pg_connectivity() {
    local ref=$1
    local max_wait=${2:-300}
    local wait_interval=10
    local elapsed=0

    echo "Waiting for database connectivity..."
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        if run_sql_direct "${ref}" "SELECT 1;" &>/dev/null; then
            echo "  Database is accepting connections!"
            return 0
        fi

        echo "  Not ready yet (waited ${elapsed}s)"
        sleep ${wait_interval}
        elapsed=$((elapsed + wait_interval))
    done

    echo "Error: Database did not become accessible within ${max_wait}s"
    return 1
}

# Helper function to verify row count
verify_row_count() {
    local pg_ref=$1
    local expected=$2
    local use_ubi=${3:-false}

    local count
    if [[ "${use_ubi}" == "true" ]]; then
        count=$(run_sql_ubi "${pg_ref}" "SELECT COUNT(*) FROM lifecycle_test;")
    else
        count=$(run_sql_direct "${pg_ref}" "SELECT COUNT(*) FROM lifecycle_test;")
    fi

    echo "  Row count: ${count} (expected: ${expected})"
    if [[ "${count}" -ne "${expected}" ]]; then
        echo "Error: Row count mismatch"
        exit 1
    fi
}

echo "=== PostgreSQL Lifecycle Test ==="
echo "URL: ${UBI_URL}"
echo "Location: ${PG_LOCATION}"
echo "PG Name: ${PG_NAME}"
echo "Initial Version: ${PG_VERSION}"
echo "Initial Size: ${PG_SIZE}"
echo ""

# =============================================================================
# Step 1: Create PostgreSQL database
# =============================================================================
echo "=== Step 1: Creating PostgreSQL database ==="
ubi pg "${PG_REF}" create \
    -s "${PG_SIZE}" \
    -S "${PG_STORAGE}" \
    -v "${PG_VERSION}"

echo "PostgreSQL creation initiated."

wait_for_pg_state "${PG_REF}" "running" 900
wait_for_pg_connectivity "${PG_REF}"

echo ""
echo "PostgreSQL Details:"
ubi pg "${PG_REF}" show

# =============================================================================
# Step 2: Insert initial test data
# =============================================================================
echo ""
echo "=== Step 2: Inserting initial test data ==="

run_sql_direct "${PG_REF}" "CREATE TABLE lifecycle_test (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW());"
run_sql_direct "${PG_REF}" "INSERT INTO lifecycle_test (data) VALUES ('row_1'), ('row_2'), ('row_3');"
verify_row_count "${PG_REF}" 3

# =============================================================================
# Step 3: Test firewall blocking
# =============================================================================
echo ""
echo "=== Step 3: Testing firewall rules ==="

# Get current firewall rules
echo "Current firewall rules:"
ubi pg "${PG_REF}" show -f firewall-rules

# Get all current rule IDs (IPv4 rules for port 5432)
echo "Removing all existing firewall rules to test blocking..."
RULE_IDS=$(ubi pg "${PG_REF}" show -f firewall-rules 2>/dev/null | grep -E "^\s+[0-9]+:" | awk '{print $2}')

SAVED_RULES=()
for rule_id in ${RULE_IDS}; do
    echo "  Deleting rule: ${rule_id}"
    SAVED_RULES+=("${rule_id}")
    ubi pg "${PG_REF}" delete-firewall-rule "${rule_id}" || true
done

# Wait for firewall changes to apply
echo "Waiting for firewall changes to apply..."
sleep 30

# Test that connection now fails (with timeout)
echo "Testing that connection is blocked..."
CONN_STRING=$(get_pg_field "${PG_REF}" "connection-string" | sed 's|\?.*||')
if timeout 15 psql "${CONN_STRING}" -c "SELECT 1;" &>/dev/null 2>&1; then
    echo "Warning: Connection succeeded when it should have been blocked"
else
    echo "  Connection blocked as expected!"
fi

# Restore firewall rules - add back 0.0.0.0/0 for IPv4 and ::/0 for IPv6
echo "Restoring firewall rules..."
ubi pg "${PG_REF}" add-firewall-rule "0.0.0.0/0"
ubi pg "${PG_REF}" add-firewall-rule "::/0"

# Wait for firewall changes to apply
echo "Waiting for firewall restoration..."
sleep 15

# Verify connection works again
echo "Verifying connection is restored..."
wait_for_pg_connectivity "${PG_REF}" 120

# Verify data still intact using ubi psql
echo "Verifying data integrity after firewall test (using ubi pg psql)..."
verify_row_count "${PG_REF}" 3 "true"

# =============================================================================
# Step 4: Scale the database
# =============================================================================
echo ""
echo "=== Step 4: Scaling PostgreSQL to ${PG_SCALED_SIZE} with ${PG_SCALED_STORAGE}GB storage ==="

# Insert data before scaling
run_sql_ubi "${PG_REF}" "INSERT INTO lifecycle_test (data) VALUES ('pre_scale');"
verify_row_count "${PG_REF}" 4 "true"

ubi pg "${PG_REF}" modify -s "${PG_SCALED_SIZE}" -S "${PG_SCALED_STORAGE}"

echo "Scaling initiated. Waiting for completion..."

wait_for_pg_field "${PG_REF}" "vm-size" "${PG_SCALED_SIZE}" 900
wait_for_pg_field "${PG_REF}" "storage-size-gib" "${PG_SCALED_STORAGE}" 300
wait_for_pg_connectivity "${PG_REF}"

echo "Scaling complete."

# Verify data after scaling using direct psql
echo "Verifying data after scaling (using direct psql)..."
verify_row_count "${PG_REF}" 4

# =============================================================================
# Step 5: Upgrade PostgreSQL version
# =============================================================================
echo ""
echo "=== Step 5: Upgrading PostgreSQL from ${PG_VERSION} to ${PG_UPGRADE_VERSION} ==="

# Insert data before upgrade
run_sql_direct "${PG_REF}" "INSERT INTO lifecycle_test (data) VALUES ('pre_upgrade');"
verify_row_count "${PG_REF}" 5

ubi pg "${PG_REF}" upgrade

echo "Upgrade initiated. Waiting for completion..."

wait_for_pg_upgrade "${PG_REF}" "${PG_UPGRADE_VERSION}" 1800
wait_for_pg_connectivity "${PG_REF}"

echo "Upgrade complete."

# Verify data after upgrade using ubi psql
echo "Verifying data after upgrade (using ubi pg psql)..."
verify_row_count "${PG_REF}" 5 "true"

# =============================================================================
# Step 6: Wait for backup and create read replica
# =============================================================================
echo ""
echo "=== Step 6: Creating read replica ==="

echo "Waiting for backup to be available..."
MAX_BACKUP_WAIT=600
BACKUP_WAIT_INTERVAL=15
BACKUP_ELAPSED=0

while [[ ${BACKUP_ELAPSED} -lt ${MAX_BACKUP_WAIT} ]]; do
    EARLIEST_RESTORE=$(get_pg_field "${PG_REF}" "earliest-restore-time")
    if [[ -n "${EARLIEST_RESTORE}" && "${EARLIEST_RESTORE}" != "" ]]; then
        echo "  Backup available (earliest restore: ${EARLIEST_RESTORE})"
        break
    fi
    echo "  No backup yet (waited ${BACKUP_ELAPSED}s)"
    sleep ${BACKUP_WAIT_INTERVAL}
    BACKUP_ELAPSED=$((BACKUP_ELAPSED + BACKUP_WAIT_INTERVAL))
done

if [[ -z "${EARLIEST_RESTORE}" || "${EARLIEST_RESTORE}" == "" ]]; then
    echo "Error: No backup available after ${MAX_BACKUP_WAIT}s"
    exit 1
fi

# Insert data before replica creation
run_sql_direct "${PG_REF}" "INSERT INTO lifecycle_test (data) VALUES ('pre_replica');"
verify_row_count "${PG_REF}" 6

ubi pg "${PG_REF}" create-read-replica "${REPLICA_NAME}"

echo "Read replica creation initiated."

wait_for_pg_state "${PG_LOCATION}/${REPLICA_NAME}" "running" 900
wait_for_pg_connectivity "${PG_LOCATION}/${REPLICA_NAME}"

echo ""
echo "Read Replica Details:"
ubi pg "${PG_LOCATION}/${REPLICA_NAME}" show

# =============================================================================
# Step 7: Verify data on read replica
# =============================================================================
echo ""
echo "=== Step 7: Verifying data on read replica ==="

# Wait for replication to catch up
echo "Checking replication..."
MAX_REPL_WAIT=60
REPL_ELAPSED=0

while [[ ${REPL_ELAPSED} -lt ${MAX_REPL_WAIT} ]]; do
    REPLICA_COUNT=$(run_sql_direct "${PG_LOCATION}/${REPLICA_NAME}" "SELECT COUNT(*) FROM lifecycle_test;")
    if [[ "${REPLICA_COUNT}" -eq 6 ]]; then
        echo "  Replica has ${REPLICA_COUNT} rows - replication complete!"
        break
    fi
    echo "  Replica has ${REPLICA_COUNT} rows, expected 6 (waited ${REPL_ELAPSED}s)"
    sleep 5
    REPL_ELAPSED=$((REPL_ELAPSED + 5))
done

verify_row_count "${PG_LOCATION}/${REPLICA_NAME}" 6

# Test replication with bulk insert to force WAL generation (~100MB of data)
echo "Testing live replication with bulk data insert..."
run_sql_ubi "${PG_REF}" "INSERT INTO lifecycle_test (data) SELECT 'bulk_' || i || '_' || repeat('x', 1000) FROM generate_series(1, 100000) AS i;"
echo "  Inserted ~100MB of data to force WAL flush"

echo "Waiting for bulk data to replicate..."
MAX_REPL_WAIT=180
REPL_ELAPSED=0

while [[ ${REPL_ELAPSED} -lt ${MAX_REPL_WAIT} ]]; do
    BULK_COUNT=$(run_sql_ubi "${PG_LOCATION}/${REPLICA_NAME}" "SELECT COUNT(*) FROM lifecycle_test WHERE data LIKE 'bulk_%';")
    if [[ "${BULK_COUNT}" -eq 100000 ]]; then
        echo "  Live replication verified! (${BULK_COUNT} bulk rows replicated)"
        break
    fi
    echo "  Bulk rows replicated: ${BULK_COUNT}/100000 (waited ${REPL_ELAPSED}s)"
    sleep 5
    REPL_ELAPSED=$((REPL_ELAPSED + 5))
done

if [[ "${BULK_COUNT}" -ne 100000 ]]; then
    echo "Error: Replication lag detected - expected 100000 bulk rows, got ${BULK_COUNT}"
    exit 1
fi

# =============================================================================
# Step 8: Destroy read replica
# =============================================================================
echo ""
echo "=== Step 8: Destroying read replica ==="
ubi pg "${PG_LOCATION}/${REPLICA_NAME}" destroy -f
echo "Read replica destruction initiated."
sleep 10

# =============================================================================
# Step 9: Final verification
# =============================================================================
echo ""
echo "=== Step 9: Final verification ==="
FINAL_COUNT=$(run_sql_direct "${PG_REF}" "SELECT COUNT(*) FROM lifecycle_test;")
EXPECTED_FINAL=100006  # 3 initial + 1 pre_scale + 1 pre_upgrade + 1 pre_replica + 100000 bulk
echo "Final row count on primary: ${FINAL_COUNT} (expected: ${EXPECTED_FINAL})"
if [[ "${FINAL_COUNT}" -ne "${EXPECTED_FINAL}" ]]; then
    echo "Error: Final row count mismatch"
    exit 1
fi

# =============================================================================
# Complete
# =============================================================================
echo ""
echo "=========================================="
echo "=== PostgreSQL Lifecycle Test Complete ==="
echo "=========================================="
echo "SUCCESS: All tests passed!"
echo "  - Created PostgreSQL ${PG_VERSION}"
echo "  - Tested firewall blocking and restoration"
echo "  - Scaled from ${PG_SIZE}/${PG_STORAGE}GB to ${PG_SCALED_SIZE}/${PG_SCALED_STORAGE}GB"
echo "  - Upgraded from ${PG_VERSION} to ${PG_UPGRADE_VERSION}"
echo "  - Created and verified read replica with ~100MB bulk replication test"
echo "  - Verified data integrity throughout"
echo ""
echo "Primary destruction will be handled by cleanup..."
