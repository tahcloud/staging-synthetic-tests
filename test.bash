#!/bin/bash

set -uex
set -o pipefail

source ./helper.bash

ubi ps "${LOCATION}/subnet-${SUFFIX}" create

ubi vm "${LOCATION}/vm-${SUFFIX}" create \
  --size=standard-2 \
  --storage-size=40 \
  --boot-image=ubuntu-noble \
  --private-subnet-id="subnet-${SUFFIX}" \
  --unix-user=ubi \
  "$(cat ~/.ssh/id_ed25519.pub)"

wait_for_ssh "vm-${SUFFIX}"

ubi vm "${LOCATION}/vm-${SUFFIX}" ssh -- uptime

ubi vm "${LOCATION}/vm-${SUFFIX}" destroy

ubi ps "${LOCATION}/subnet-${SUFFIX}" destroy
