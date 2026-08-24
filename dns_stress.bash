#!/bin/bash

set -uex
set -o pipefail

DURATION="${DURATION:-60}"
QPS="${QPS:-200}"
UNIQUE_QPS="${UNIQUE_QPS:-50}"
RUN_TAG="${RUN_TAG:-local-$$}"
OUT_DIR="${OUT_DIR:-dns-stress-out}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

mkdir -p "${OUT_DIR}"

# The job-level timeout is 30 minutes; leave room for provisioning,
# apt, and reporting so the stress never dies as a cancelled job.
if [ "${DURATION}" -gt 1500 ]; then
  echo "::error::DURATION ${DURATION}s exceeds the job timeout budget (max 1500)"
  exit 1
fi

# The DHCP-provided resolver is the per-VM dnsmasq. An ipv6_disabled
# project hands out 8.8.8.8 directly instead, and the stress would not
# touch dnsmasq at all, so refuse to run in that case.
RESOLVER=$(awk '/^nameserver/ {print $2; exit}' /run/systemd/resolve/resolv.conf 2>/dev/null ||
  awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
echo "resolver: ${RESOLVER}"
if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
  case "${RESOLVER}" in
    10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) ;;
    *)
      echo "::error::resolver ${RESOLVER} is not the subnet-local dnsmasq (ipv6_disabled project?)"
      exit 1
      ;;
  esac
  # The metal dnsmasq also listens on a fixed ULA; its absence suggests
  # an alien (non-metal) runner whose resolver is not the code under test.
  if ! resolvectl dns 2>/dev/null | grep -qiE 'fd00:0?b1c:100d:53::'; then
    echo "::warning::fd00:0b1c:100d:53:: is not among the DNS servers; this may not be a metal dnsmasq"
  fi
fi

# A wrong-but-valid empty answer would not show up in dnsperf's rcode
# stats, so assert real answer contents before and after the stress.
check_answers() {
  local d out
  for d in www.google.com github.com www.cloudflare.com; do
    # dig prints its error chatter to stdout, so non-empty output is not
    # an answer: require a successful exit and an address-shaped line.
    if ! out=$(dig +short +time=3 +tries=2 "@${RESOLVER}" "${d}" A) ||
      ! grep -qE '^[0-9]+\.' <<<"${out}"; then
      echo "::error::no usable A answer for ${d} from ${RESOLVER}: ${out:-empty}"
      return 1
    fi
  done
}
check_answers

CACHED_FILE="${OUT_DIR}/cached.txt"
UNIQUE_FILE="${OUT_DIR}/unique.txt"
: >"${CACHED_FILE}"
for d in www.google.com github.com api.github.com www.cloudflare.com ubicloud.com \
  registry.npmjs.org archive.ubuntu.com pypi.org www.amazon.com www.wikipedia.org; do
  printf '%s A\n%s AAAA\n' "${d}" "${d}" >>"${CACHED_FILE}"
done

# One line per query, each name unique to this run and runner: a
# guaranteed dnsmasq cache miss that must travel the upstream path.
awk -v n="$((UNIQUE_QPS * DURATION))" -v tag="${RUN_TAG}" \
  'BEGIN { for (i = 1; i <= n; i++) print "q" i "-" tag ".dns-stress.ubicloud.com A" }' >"${UNIQUE_FILE}"

# Three concurrent load shapes per runner: cached names over UDP (loops
# the file, mostly served from dnsmasq's cache), unique names over UDP
# (one pass, all upstream misses), and cached names over TCP.
dnsperf -s "${RESOLVER}" -d "${CACHED_FILE}" -l "${DURATION}" -Q "${QPS}" -c 20 -q 100 \
  >"${OUT_DIR}/cached.out" 2>&1 &
cached_pid=$!
dnsperf -s "${RESOLVER}" -d "${UNIQUE_FILE}" -l "${DURATION}" -Q "${UNIQUE_QPS}" -c 10 -q 50 -n 1 \
  >"${OUT_DIR}/unique.out" 2>&1 &
unique_pid=$!
dnsperf -m tcp -s "${RESOLVER}" -d "${CACHED_FILE}" -l "${DURATION}" -Q 20 -c 5 -q 20 \
  >"${OUT_DIR}/tcp.out" 2>&1 &
tcp_pid=$!
wait "${cached_pid}" "${unique_pid}" "${tcp_pid}"

check_answers

fail=0
{
  echo "## DNS stress (${RUN_TAG})"
  echo "| scenario | sent | completed | lost | rcodes | avg latency (s) |"
  echo "| --- | --- | --- | --- | --- | --- |"
} >>"${SUMMARY}"

report() {
  local name="$1" file="$2" allowed="$3"
  local sent completed lost bad rcodes avg max_lost
  cat "${file}"
  sent=$(awk '/Queries sent:/ {print $3}' "${file}")
  completed=$(awk '/Queries completed:/ {print $3}' "${file}")
  lost=$(awk '/Queries lost:/ {print $3}' "${file}")
  rcodes=$(awk -F': *' '/Response codes:/ {print $2}' "${file}")
  avg=$(awk '/Average Latency/ {print $4; exit}' "${file}")
  echo "| ${name} | ${sent:-0} | ${completed:-0} | ${lost:-0} | ${rcodes:-n/a} | ${avg:-n/a} |" >>"${SUMMARY}"

  if [ "${sent:-0}" -eq 0 ]; then
    echo "::error::${name}: no queries were sent"
    fail=1
    return 0
  fi

  # Allow 0.1% UDP loss; anything above reads as a resolution outage.
  max_lost=$(((sent + 999) / 1000))
  if [ "${lost}" -gt "${max_lost}" ]; then
    echo "::error::${name}: ${lost}/${sent} queries lost"
    fail=1
  fi

  # Any rcode outside the scenario's expected set fails: for names that
  # exist, an NXDOMAIN is exactly the lying-upstream class winning the
  # all-servers race, not a tolerable response.
  bad=$(awk -v allowed="${allowed}" '/Response codes:/ {
      for (i = 1; i < NF; i++)
        if ($i ~ /^[A-Z]+$/ && $(i + 1) ~ /^[0-9]+$/ && allowed !~ ("(^| )" $i "( |$)")) s += $(i + 1)
    } END { print s + 0 }' "${file}")
  if [ "${bad}" -gt 0 ]; then
    echo "::error::${name}: ${bad} responses outside expected rcodes (${allowed})"
    fail=1
  fi
}

report cached "${OUT_DIR}/cached.out" NOERROR
report unique "${OUT_DIR}/unique.out" "NOERROR NXDOMAIN"
report tcp "${OUT_DIR}/tcp.out" NOERROR

exit "${fail}"
