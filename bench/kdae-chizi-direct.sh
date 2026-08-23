#!/usr/bin/env bash
set -euo pipefail

CHIZI_BIN=${CHIZI_BIN:-/tmp/bench-bin/chizi-sing-box}
KDAE_BIN=${KDAE_BIN:-/tmp/bench-bin/kdae}
BENCH_BIN=${BENCH_BIN:-/tmp/bench-bin/interception-bench}
OUT=${OUT:-$PWD/bench-results}
REPS=${REPS:-3}
DURATION=${DURATION:-2s}
WARMUP=${WARMUP:-500ms}
CONCURRENCY=${CONCURRENCY:-32}
TCP_PAYLOAD=${TCP_PAYLOAD:-32768}
UDP_PAYLOAD=${UDP_PAYLOAD:-1200}

for f in "$CHIZI_BIN" "$KDAE_BIN" "$BENCH_BIN"; do
  test -x "$f" || { echo "missing executable: $f" >&2; exit 1; }
done

mkdir -p "$OUT"/{raw,time,logs,env}

TOKEN="${GITHUB_RUN_ID:-local}-$$"
APP="kc-app-$TOKEN"
RTR="kc-rtr-$TOKEN"
SRV="kc-srv-$TOKEN"
AIF="ka$$"
RLIF="krl$$"
RWIF="krw$$"
SIF="ks$$"
APP_IP=10.89.0.2
RL_IP=10.89.0.1
RW_IP=45.45.45.1
SERVER_IP=45.45.45.2
SERVER_PORT=20990
CHIZI_CFG="$OUT/chizi.json"
KDAE_CFG="$OUT/kdae.dae"
DAEMON_PID=
SERVER_PID=

NCPU=$(nproc)
if (( NCPU >= 4 )); then
  CLIENT_CPU=1
  SERVER_CPU=2
  DAEMON_CPU=3
elif (( NCPU == 3 )); then
  CLIENT_CPU=0
  SERVER_CPU=1
  DAEMON_CPU=2
else
  CLIENT_CPU=0
  SERVER_CPU=$((NCPU-1))
  DAEMON_CPU=0
fi

echo "nproc=$NCPU client_cpu=$CLIENT_CPU server_cpu=$SERVER_CPU daemon_cpu=$DAEMON_CPU" | tee "$OUT/env/cpu-placement.txt"
uname -a | tee "$OUT/env/uname.txt"
lscpu > "$OUT/env/lscpu.txt" 2>&1 || true

cleanup() {
  set +e
  if [[ -n ${DAEMON_PID:-} ]]; then
    kill -TERM "$DAEMON_PID" 2>/dev/null
    for _ in $(seq 1 30); do
      kill -0 "$DAEMON_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=
  fi
  if [[ -n ${SERVER_PID:-} ]]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  fi
  ip netns del "$APP" 2>/dev/null || true
  ip netns del "$RTR" 2>/dev/null || true
  ip netns del "$SRV" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

proc_ticks() {
  local pid=$1
  if [[ -r /proc/$pid/stat ]]; then
    awk '{print $14+$15}' "/proc/$pid/stat"
  else
    echo 0
  fi
}

setup_topology() {
  ip netns add "$APP"
  ip netns add "$RTR"
  ip netns add "$SRV"

  ip link add "$AIF" type veth peer name "$RLIF"
  ip link set "$AIF" netns "$APP"
  ip link set "$RLIF" netns "$RTR"
  ip link add "$RWIF" type veth peer name "$SIF"
  ip link set "$RWIF" netns "$RTR"
  ip link set "$SIF" netns "$SRV"

  ip -n "$APP" link set lo up
  ip -n "$APP" addr add "$APP_IP/24" dev "$AIF"
  ip -n "$APP" link set "$AIF" up
  ip -n "$APP" route add default via "$RL_IP"

  ip -n "$RTR" link set lo up
  ip -n "$RTR" addr add "$RL_IP/24" dev "$RLIF"
  ip -n "$RTR" addr add "$RW_IP/24" dev "$RWIF"
  ip -n "$RTR" link set "$RLIF" up
  ip -n "$RTR" link set "$RWIF" up
  ip netns exec "$RTR" sysctl -q -w net.ipv4.ip_forward=1
  ip netns exec "$RTR" sysctl -q -w net.ipv4.conf.all.rp_filter=0 || true
  ip netns exec "$RTR" sysctl -q -w net.ipv4.conf.default.rp_filter=0 || true
  ip netns exec "$RTR" sysctl -q -w "net.ipv4.conf.$RLIF.rp_filter=0" || true
  ip netns exec "$RTR" sysctl -q -w "net.ipv4.conf.$RWIF.rp_filter=0" || true
  ip netns exec "$RTR" iptables -P FORWARD ACCEPT
  ip netns exec "$RTR" iptables -F FORWARD

  ip -n "$SRV" link set lo up
  ip -n "$SRV" addr add "$SERVER_IP/24" dev "$SIF"
  ip -n "$SRV" link set "$SIF" up
  ip -n "$SRV" route add 10.89.0.0/24 via "$RW_IP"

  for nsdev in "$APP:$AIF" "$RTR:$RLIF" "$RTR:$RWIF" "$SRV:$SIF"; do
    ns=${nsdev%%:*}; dev=${nsdev#*:}
    {
      echo "### $ns/$dev"
      ip netns exec "$ns" ethtool -k "$dev" || true
    } >> "$OUT/env/offloads.txt" 2>&1
  done

  ip netns exec "$APP" ping -c 3 -W 1 "$SERVER_IP" >/dev/null
}

start_server() {
  ip netns exec "$SRV" taskset -c "$SERVER_CPU" "$BENCH_BIN" -mode server -listen ":$SERVER_PORT" \
    > "$OUT/logs/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$OUT/logs/server.log" >&2
      return 1
    fi
    if ip netns exec "$SRV" ss -H -ltn "sport = :$SERVER_PORT" | grep -q .; then
      return 0
    fi
    sleep 0.1
  done
  echo "server not ready" >&2
  return 1
}

write_chizi_config() {
  cat > "$CHIZI_CFG" <<EOF
{
  "log": {"level": "info", "timestamp": false},
  "inbounds": [
    {
      "type": "ebpf",
      "tag": "benchmark-in",
      "mode": "shared",
      "network": ["tcp", "udp"],
      "bypass_rule_set": ["real-direct"],
      "shared": {
        "dns_mode": "off",
        "interface": ["$RLIF"],
        "ipv6_mode": "off",
        "bypass_private_address": false,
        "advanced": {"data_plane": "auto", "tc_priority": 1}
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {
    "rule_set": [
      {"type": "inline", "tag": "real-direct", "rules": [{"ip_cidr": ["$SERVER_IP/32"]}]}
    ],
    "final": "direct"
  }
}
EOF
}

write_kdae_config() {
  cat > "$KDAE_CFG" <<EOF
global {
    tproxy_port: 12345
    tproxy_port_protect: true
    log_level: info
    disable_waiting_network: true
    lan_interface: $RLIF
    wan_interface: $RWIF
    auto_config_kernel_parameter: true
    dial_mode: ip
    sniffing_timeout: 0ms
    so_mark_from_dae: 0
    pprof_port: 0
}

routing {
    dip($SERVER_IP/32) -> direct
    fallback: block
}
EOF
}

stop_variant() {
  if [[ -n ${DAEMON_PID:-} ]]; then
    kill -TERM "$DAEMON_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$DAEMON_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
      kill -KILL "$DAEMON_PID" 2>/dev/null || true
    fi
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=
  fi
  sleep 0.3
}

start_chizi() {
  local label=$1
  write_chizi_config
  ip netns exec "$RTR" taskset -c "$DAEMON_CPU" "$CHIZI_BIN" run -c "$CHIZI_CFG" \
    > "$OUT/logs/chizi-$label.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 60); do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "CHIZI exited" >&2
      cat "$OUT/logs/chizi-$label.log" >&2
      return 1
    fi
    if grep -q 'eBPF shared-network TC interception ready' "$OUT/logs/chizi-$label.log"; then
      ip netns exec "$RTR" tc qdisc show dev "$RLIF" > "$OUT/logs/chizi-$label-tc-qdisc.txt" 2>&1 || true
      ip netns exec "$RTR" tc filter show dev "$RLIF" ingress > "$OUT/logs/chizi-$label-tc-ingress.txt" 2>&1 || true
      return 0
    fi
    sleep 0.1
  done
  echo "CHIZI did not report ready" >&2
  cat "$OUT/logs/chizi-$label.log" >&2
  return 1
}

start_kdae() {
  local label=$1
  write_kdae_config
  ip netns exec "$RTR" taskset -c "$DAEMON_CPU" "$KDAE_BIN" run -c "$KDAE_CFG" --disable-pidfile --disable-sudo \
    > "$OUT/logs/kdae-$label.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 100); do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "KDAE exited" >&2
      cat "$OUT/logs/kdae-$label.log" >&2
      return 1
    fi
    # dae does not expose a single stable ready log across revisions; a live process plus
    # an attached BPF filter on the LAN interface is sufficient for this isolated test.
    if ip netns exec "$RTR" tc filter show dev "$RLIF" ingress 2>/dev/null | grep -qi bpf; then
      ip netns exec "$RTR" tc qdisc show dev "$RLIF" > "$OUT/logs/kdae-$label-tc-qdisc.txt" 2>&1 || true
      ip netns exec "$RTR" tc filter show dev "$RLIF" ingress > "$OUT/logs/kdae-$label-tc-ingress.txt" 2>&1 || true
      return 0
    fi
    sleep 0.1
  done
  echo "KDAE did not attach LAN ingress BPF filter" >&2
  cat "$OUT/logs/kdae-$label.log" >&2
  ip netns exec "$RTR" tc filter show dev "$RLIF" ingress >&2 || true
  return 1
}

start_variant() {
  local variant=$1 label=$2
  case "$variant" in
    direct) DAEMON_PID=; sleep 0.2 ;;
    chizi) start_chizi "$label" ;;
    kdae) start_kdae "$label" ;;
    *) echo "unknown variant $variant" >&2; return 2 ;;
  esac
}

run_one() {
  local variant=$1 rep=$2 scenario=$3 duration=$4 warmup=$5
  local dir="$OUT/raw/$variant"
  mkdir -p "$dir" "$OUT/time/$variant"
  local json="$dir/${rep}-${scenario}.json"
  local tf="$OUT/time/$variant/${rep}-${scenario}.txt"
  local sf="$OUT/time/$variant/${rep}-${scenario}-server-ticks.txt"
  local df="$OUT/time/$variant/${rep}-${scenario}-daemon-ticks.txt"
  local s0 s1 d0 d1
  s0=$(proc_ticks "$SERVER_PID")
  if [[ -n ${DAEMON_PID:-} ]]; then d0=$(proc_ticks "$DAEMON_PID"); else d0=0; fi
  /usr/bin/time -f 'elapsed=%e user=%U sys=%S maxrss_kb=%M vcsw=%w ivcsw=%c' -o "$tf" \
    ip netns exec "$APP" taskset -c "$CLIENT_CPU" setpriv --reuid=65534 --regid=65534 --clear-groups \
    "$BENCH_BIN" -mode client -target "$SERVER_IP:$SERVER_PORT" -scenario "$scenario" \
      -duration "$duration" -warmup "$warmup" -concurrency "$CONCURRENCY" \
      -tcp-payload-size "$TCP_PAYLOAD" -udp-payload-size "$UDP_PAYLOAD" > "$json"
  s1=$(proc_ticks "$SERVER_PID")
  if [[ -n ${DAEMON_PID:-} ]]; then d1=$(proc_ticks "$DAEMON_PID"); else d1=0; fi
  echo $((s1-s0)) > "$sf"
  echo $((d1-d0)) > "$df"
  jq -e '.results | length == 1 and .[0].errors == 0 and .[0].rate > 0' "$json" >/dev/null
}

verify_chizi_bypass_cache() {
  local tool
  tool=$(command -v bpftool || true)
  if [[ -z $tool ]]; then
    tool=$(find /usr/lib/linux-tools -type f -name bpftool -perm -111 2>/dev/null | head -n1 || true)
  fi
  if [[ -z $tool ]]; then
    echo "bpftool unavailable; skip bypass-map occupancy proof" | tee -a "$OUT/env/validation.txt"
    return 0
  fi
  "$tool" map show > "$OUT/logs/bpftool-maps-chizi.txt" 2>&1 || true
  local ids
  ids=$("$tool" -j map show 2>/dev/null | jq -r '.[] | select(.name=="sb_sh_bypass") | .id' || true)
  if [[ -z $ids ]]; then
    echo "CHIZI sb_sh_bypass map not found" | tee -a "$OUT/env/validation.txt"
    return 1
  fi
  local total=0 id n
  for id in $ids; do
    n=$("$tool" -j map dump id "$id" 2>/dev/null | jq 'length' || echo 0)
    total=$((total+n))
  done
  echo "chizi_bypass_flow_entries=$total" | tee -a "$OUT/env/validation.txt"
  (( total > 0 ))
}

summarize() {
python3 - "$OUT" <<'PY'
import json, statistics, pathlib, re, sys
root=pathlib.Path(sys.argv[1])
variants=['direct','kdae','chizi']
scenarios=['tcp-short','tcp-upload','tcp-download','udp-pps','udp-unconnected-pps','udp-churn']
rows={}
for v in variants:
    for s in scenarios:
        vals=[]
        unit=None
        for p in sorted((root/'raw'/v).glob(f'*-{s}.json')):
            d=json.loads(p.read_text())
            r=d['results'][0]
            vals.append(float(r['rate'])); unit=r['unit']
        if vals: rows[(v,s)]=(statistics.median(vals),unit,len(vals))

def fmt(x,u):
    if u=='bit/s':
        return f'{x/1e9:.3f} Gbit/s' if x>=1e9 else f'{x/1e6:.3f} Mbit/s'
    if x>=1e6: return f'{x/1e6:.3f} M {u}'
    if x>=1e3: return f'{x/1e3:.3f} k {u}'
    return f'{x:.2f} {u}'

lines=[]
lines.append('# KDAE vs CHIZI Real Direct')
lines.append('')
lines.append('| Scenario | Direct | KDAE | CHIZI | CHIZI/KDAE |')
lines.append('|---|---:|---:|---:|---:|')
for s in scenarios:
    if not all((v,s) in rows for v in variants): continue
    d,du,_=rows[('direct',s)]; k,ku,_=rows[('kdae',s)]; c,cu,_=rows[('chizi',s)]
    lines.append(f'| {s} | {fmt(d,du)} | {fmt(k,ku)} | {fmt(c,cu)} | {c/k*100:.2f}% |')
lines.append('')
lines.append('## Client system CPU time (median seconds per scenario run)')
lines.append('')
lines.append('| Scenario | Direct | KDAE | CHIZI |')
lines.append('|---|---:|---:|---:|')
for s in scenarios:
    med={}
    for v in variants:
        vals=[]
        for p in sorted((root/'time'/v).glob(f'*-{s}.txt')):
            m=re.search(r'\bsys=([0-9.]+)',p.read_text())
            if m: vals.append(float(m.group(1)))
        if vals: med[v]=statistics.median(vals)
    if len(med)==3:
        lines.append(f"| {s} | {med['direct']:.3f} | {med['kdae']:.3f} | {med['chizi']:.3f} |")

out='\n'.join(lines)+'\n'
(root/'summary.md').write_text(out)
print(out)
PY
}

setup_topology
start_server

# Save base topology and ensure forwarding works with no interception.
ip netns exec "$APP" ping -c 2 -W 1 "$SERVER_IP" >/dev/null

# Functional smoke: each direct path must actually pass traffic before timing.
for v in direct chizi kdae; do
  echo "=== smoke $v ==="
  start_variant "$v" smoke
  run_one "$v" smoke tcp-short 300ms 50ms
  if [[ $v == chizi ]]; then
    verify_chizi_bypass_cache
  fi
  stop_variant
done

scenarios=(tcp-short tcp-upload tcp-download udp-pps udp-unconnected-pps udp-churn)
for rep in $(seq 1 "$REPS"); do
  mapfile -t order < <(printf '%s\n' direct kdae chizi | shuf)
  echo "=== repetition $rep order: ${order[*]} ==="
  for v in "${order[@]}"; do
    start_variant "$v" "$rep"
    # warm the exact direct path before measured scenarios
    run_one "$v" "${rep}-warm" tcp-upload 300ms 50ms
    for s in "${scenarios[@]}"; do
      echo "run rep=$rep variant=$v scenario=$s"
      run_one "$v" "$rep" "$s" "$DURATION" "$WARMUP"
    done
    stop_variant
  done
done

summarize

echo '--- CHIZI ready logs ---'
grep -h 'eBPF shared-network TC interception ready' "$OUT"/logs/chizi-*.log || true
echo '--- KDAE tail ---'
tail -n 30 "$OUT"/logs/kdae-1.log 2>/dev/null || true
