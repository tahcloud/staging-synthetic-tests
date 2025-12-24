#!/bin/bash

# Helper function: wait for VM to be SSH-accessible
wait_for_ssh() {
  local vm_name=$1
  local max_attempts=${2:-60}
  local attempt=0

  echo "Waiting for SSH access to ${vm_name}..."
  while [ $attempt -lt $max_attempts ]; do
    if ubi vm "${LOCATION}/${vm_name}" ssh -- echo "SSH OK"; then
      echo "SSH to ${vm_name} is ready!"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "Timeout waiting for SSH to ${vm_name}"
  return 1
}

# Helper function: get field with retry
get_field_with_retry() {
  local resource_type=$1
  local resource_name=$2
  local field=$3
  local max_attempts=${4:-30}
  local attempt=0

  while [ $attempt -lt $max_attempts ]; do
    local value=$(ubi ${resource_type} "${LOCATION}/${resource_name}" show -f ${field} 2>/dev/null | awk -F': ' 'NF==2 {print $2; exit}' || echo "")
    if [ -n "$value" ] && [ "$value" != "null" ] && [ "$value" != "" ]; then
      echo "$value"
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  echo ""
  return 1
}
