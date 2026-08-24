#!/bin/bash

set -uex
set -o pipefail

RUN_TAG="${RUN_TAG:-local-$$}"
OUT_DIR="${OUT_DIR:-dns-stress-out}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
LOG="${OUT_DIR}/net-health.log"

mkdir -p "${OUT_DIR}"
: >"${LOG}"

fail=0
declare -a rows

check() {
  local name="$1" ok="$2" detail="$3" gate="${4:-gate}"
  rows+=("| ${name} | ${ok} | ${detail} |")
  echo "${name}: ${ok} (${detail})" >>"${LOG}"
  if [ "${ok}" != "ok" ] && [ "${gate}" = "gate" ]; then
    echo "::error::net-health ${name}: ${detail}"
    fail=1
  fi
}

# Public addresses per family, as the internet sees this instance. The
# IPv4 one is the NAT address, not on any guest interface.
PUB4=$(curl -4 -sS --max-time 10 https://one.one.one.one/cdn-cgi/trace | awk -F= '/^ip=/ {print $2}' || true)
PUB6=$(curl -6 -sS --max-time 10 https://one.one.one.one/cdn-cgi/trace | awk -F= '/^ip=/ {print $2}' || true)
echo "public v4: ${PUB4:-none}, public v6: ${PUB6:-none}" >>"${LOG}"

# Outbound TCP, three endpoints per family.
out_tcp() {
  local family="$1" flag="$2" url t okc=0
  shift 2
  local times=""
  for url in "$@"; do
    if t=$(curl "${flag}" -sS -o /dev/null -w '%{time_total}' --max-time 15 "${url}"); then
      okc=$((okc + 1))
      times="${times}${t}s "
    else
      times="${times}fail(${url}) "
    fi
  done
  check "outbound tcp v${family}" "$([ "${okc}" -eq $# ] && echo ok || echo FAIL)" "${okc}/$# connected: ${times}"
}
out_tcp 4 -4 https://api.github.com/meta https://www.google.com/generate_204 https://one.one.one.one/cdn-cgi/trace
out_tcp 6 -6 https://www.google.com/generate_204 https://www.cloudflare.com/cdn-cgi/trace https://one.one.one.one/cdn-cgi/trace

# Conntrack/NAT burst: 100 concurrent outbound TLS connections through
# the shared public IPv4; conntrack must keep every tuple unique.
: >"${OUT_DIR}/burst.log"
seq 1 100 | xargs -P 25 -I{} bash -c \
  'curl -4 -sS -o /dev/null --max-time 10 https://one.one.one.one/cdn-cgi/trace && echo ok || echo fail' \
  >>"${OUT_DIR}/burst.log" 2>/dev/null || true
burst_ok=$(grep -c '^ok$' "${OUT_DIR}/burst.log" || true)
check "conntrack burst v4" "$([ "${burst_ok}" -ge 98 ] && echo ok || echo FAIL)" "${burst_ok}/100 concurrent connects"

# ICMP loss per family.
icmp() {
  local family="$1" target="$2" out loss
  out=$(ping "-${family}" -c 20 -i 0.2 -W 2 "${target}" 2>&1 | tail -2 || true)
  loss=$(grep -oE '[0-9.]+% packet loss' <<<"${out}" | grep -oE '^[0-9.]+' || echo 100)
  check "icmp v${family}" "$(awk -v l="${loss}" 'BEGIN {print (l <= 10) ? "ok" : "FAIL"}')" "${loss}% loss to ${target}"
}
icmp 4 1.1.1.1
icmp 6 2606:4700:4700::1111

# Throughput floor per family: 50 MB from Cloudflare; anything under
# 1 MB/s reads as a path pathology (MTU blackhole, heavy loss), not a
# slow link.
speed() {
  local family="$1" flag="$2" bps
  bps=$(curl "${flag}" -sS -o /dev/null -w '%{speed_download}' --max-time 60 \
    "https://speed.cloudflare.com/__down?bytes=50000000" || echo 0)
  check "throughput v${family}" "$(awk -v b="${bps}" 'BEGIN {print (b >= 1000000) ? "ok" : "FAIL"}')" \
    "$(awk -v b="${bps}" 'BEGIN {printf "%.1f MB/s", b / 1000000}')"
}
speed 4 -4
speed 6 -6

# Inbound TCP through the NAT path: connecting to the instance's own
# public IPv4 leaves the guest and re-enters through the netns
# prerouting DNAT and hairpin SNAT rules, then the port-22 firewall
# allowance -- the two nat rules the DNS stress does not touch.
sudo systemctl start ssh 2>/dev/null || sudo service ssh start 2>/dev/null || true
if [ -n "${PUB4}" ]; then
  banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/${PUB4}/22 && head -c 4 <&3" || true)
  check "inbound tcp v4 (hairpin dnat)" "$([ "${banner}" = "SSH-" ] && echo ok || echo FAIL)" "banner: ${banner:-none} from ${PUB4}:22"
else
  check "inbound tcp v4 (hairpin dnat)" FAIL "no public IPv4 discovered"
fi

# The guest's global IPv6 is on its own interface, so a self-connect
# only proves the listener; report it without gating.
if [ -n "${PUB6}" ]; then
  banner6=$(timeout 5 bash -c "exec 3<>/dev/tcp/${PUB6}/22 && head -c 4 <&3" || true)
  check "inbound tcp v6 (local listener)" "$([ "${banner6}" = "SSH-" ] && echo ok || echo FAIL)" "banner: ${banner6:-none}" nogate
else
  check "inbound tcp v6 (local listener)" FAIL "no public IPv6 discovered" nogate
fi

# Interface error counters, informational.
ip -s link show >>"${LOG}" 2>&1 || true

{
  echo "## Network health (${RUN_TAG})"
  echo "| check | result | detail |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${rows[@]}"
} >>"${SUMMARY}"

exit "${fail}"
