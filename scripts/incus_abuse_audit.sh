#!/usr/bin/env bash
set -Eeuo pipefail

# Incus 容器防滥用审计采集脚本
# 适用：Debian 12 + Incus/LXC
# 目的：只采集运行状态、配置、进程、连接、端口、任务、可疑特征，输出为一个 tar.gz，方便发给 AI/人工审查。
# 注意：本脚本会进入容器执行只读命令，不主动修改容器、不杀进程、不断网。
# 使用：bash incus_abuse_audit.sh
# 可选：KEEP_RAW=1 bash incus_abuse_audit.sh   # 保留未脱敏明文包，默认只输出 .redacted.tar.gz

TS="$(date +%F_%H%M%S)"
HOST="$(hostname 2>/dev/null || echo host)"
BASE="/root/incus-audit-${HOST}-${TS}"
OUTDIR="$BASE/report"
mkdir -p "$OUTDIR" "$OUTDIR/containers" "$OUTDIR/host"
chmod 700 "$BASE" || true

SUSPICIOUS_RE='xmrig|stratum|kinsing|kdevtmpfsi|masscan|zmap|hping3|hydra|mirai|pnscan|slowloris|goldeneye|torshammer|botnet|ddos|stress-ng|iperf3|frpc|frps|gost|xray|v2ray|sing-box|hysteria|tuic|naive|brook|trojan|ssserver|ss-local|cloudflared|ngrok|tailscale|zerotier|socat|tinyproxy|squid|x-ui|3x-ui|s-ui|v2board|sspanel|trojan-panel'
PANEL_RE='x-ui|3x-ui|s-ui|v2board|sspanel|trojan-panel|UniProxy|/sub|subscription|subscribe|sub.json|serverStatus|nezha'
SCAN_PORT_RE=':(22|23|25|465|587|445|3389|6379|9200|2375|2376)\b'

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUTDIR/summary.txt" >&2; }
run() {
  local title="$1" file="$2"; shift 2
  {
    echo "### $title"
    echo "### command: $*"
    echo "### time: $(date '+%F %T')"
    echo
    timeout 30 "$@" 2>&1 || true
  } > "$file"
}
incus_exec() {
  local c="$1" file="$2" cmd="$3"
  {
    echo "### container: $c"
    echo "### command: $cmd"
    echo "### time: $(date '+%F %T')"
    echo
    timeout 35 incus exec "$c" -- sh -lc "$cmd" 2>&1 || true
  } > "$file"
}

if ! command -v incus >/dev/null 2>&1; then
  echo "ERROR: incus command not found" >&2
  exit 1
fi

log "开始采集 Incus 容器审计信息：$BASE"

# Host 基础信息
run "host date" "$OUTDIR/host/date.txt" date -R
run "host uname" "$OUTDIR/host/uname.txt" uname -a
run "host uptime" "$OUTDIR/host/uptime.txt" uptime
run "host os-release" "$OUTDIR/host/os-release.txt" sh -c 'cat /etc/os-release 2>/dev/null || true'
run "host cpu memory" "$OUTDIR/host/cpu-memory.txt" sh -c 'nproc; free -h; vmstat 1 3 2>/dev/null || true'
run "host disk" "$OUTDIR/host/disk.txt" sh -c 'df -hT; echo; lsblk -f 2>/dev/null || true'
run "host ip addr" "$OUTDIR/host/ip-addr.txt" ip addr
run "host ip route" "$OUTDIR/host/ip-route.txt" ip route
run "host ss listen" "$OUTDIR/host/ss-listen.txt" sh -c 'ss -tulpen 2>/dev/null || true'
run "host ss all sample" "$OUTDIR/host/ss-all-sample.txt" sh -c 'ss -tunap 2>/dev/null | head -n 1000 || true'
run "host nft ruleset" "$OUTDIR/host/nft-ruleset.txt" sh -c 'nft list ruleset 2>/dev/null || true'
run "host iptables" "$OUTDIR/host/iptables.txt" sh -c 'iptables-save 2>/dev/null || true; echo; ip6tables-save 2>/dev/null || true'
run "host conntrack sample" "$OUTDIR/host/conntrack-sample.txt" sh -c 'conntrack -L 2>/dev/null | head -n 5000 || true'
run "host top processes" "$OUTDIR/host/top-processes.txt" sh -c 'ps auxww --sort=-%cpu | head -n 40; echo; ps auxww --sort=-%mem | head -n 40'
run "host journal abuse keywords" "$OUTDIR/host/journal-abuse-keywords.txt" sh -c 'journalctl --since "24 hours ago" --no-pager 2>/dev/null | egrep -ai "blocked|denied|DPT=25|DPT=465|DPT=587|masscan|zmap|xmrig|stratum|syn flood|martian|segfault" | tail -n 500 || true'
run "incus version" "$OUTDIR/host/incus-version.txt" sh -c 'incus version 2>&1 || true'
run "incus list" "$OUTDIR/host/incus-list.txt" sh -c 'incus list -c ns4tS 2>&1 || incus list 2>&1 || true'
run "incus network list" "$OUTDIR/host/incus-network-list.txt" sh -c 'incus network list 2>&1 || true'
run "incus profile list" "$OUTDIR/host/incus-profile-list.txt" sh -c 'incus profile list 2>&1 || true'
run "incus storage list" "$OUTDIR/host/incus-storage-list.txt" sh -c 'incus storage list 2>&1 || true'

# Incus profile configs
mkdir -p "$OUTDIR/host/profiles"
if incus profile list --format csv >/tmp/incus_profiles_$$ 2>/dev/null; then
  cut -d, -f1 /tmp/incus_profiles_$$ | while IFS= read -r p; do
    [ -n "$p" ] || continue
    run "incus profile show $p" "$OUTDIR/host/profiles/${p}.yaml" incus profile show "$p"
  done
fi
rm -f /tmp/incus_profiles_$$ || true

# 容器列表
if ! incus list -c n --format csv > "$OUTDIR/container_names.txt" 2>/dev/null; then
  log "无法获取容器列表"
  exit 1
fi

# conntrack/ss 原始数据供后续按容器 IP 归因
conntrack -L 2>/dev/null > "$OUTDIR/host/conntrack-full.txt" || true
ss -tunap 2>/dev/null > "$OUTDIR/host/ss-full.txt" || true

# 审计每个容器
while IFS= read -r c; do
  [ -n "$c" ] || continue
  CDIR="$OUTDIR/containers/$c"
  mkdir -p "$CDIR"
  log "采集容器：$c"

  run "incus info $c" "$CDIR/incus-info.txt" incus info "$c"
  run "incus config expanded $c" "$CDIR/incus-config-expanded.yaml" incus config show "$c" --expanded
  run "incus config local $c" "$CDIR/incus-config-local.yaml" incus config show "$c"

  # 提取 IPv4，尽量不依赖 jq
  IPV4S="$(incus list "$c" -c 4 --format csv 2>/dev/null | tr ' ' '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ' || true)"
  echo "$IPV4S" > "$CDIR/ipv4.txt"

  incus_exec "$c" "$CDIR/system-basic.txt" 'hostname; date -R; uptime; uname -a; id; cat /etc/os-release 2>/dev/null || true'
  incus_exec "$c" "$CDIR/resources.txt" 'free -h 2>/dev/null || true; df -hT 2>/dev/null || true; ps -eo pid,ppid,user,stat,pcpu,pmem,etime,comm,args --sort=-pcpu | head -n 80'
  incus_exec "$c" "$CDIR/processes-full.txt" 'ps auxww 2>/dev/null || ps -ef 2>/dev/null || true'
  incus_exec "$c" "$CDIR/listening-ports.txt" 'ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null || true'
  incus_exec "$c" "$CDIR/connections.txt" 'ss -tunap 2>/dev/null | head -n 1500 || true'
  incus_exec "$c" "$CDIR/systemd-services.txt" 'systemctl list-units --type=service --state=running --no-pager 2>/dev/null || true; echo; systemctl list-timers --all --no-pager 2>/dev/null || true'
  incus_exec "$c" "$CDIR/cron.txt" 'echo "# user crontab"; crontab -l 2>/dev/null || true; echo "# /etc/crontab"; cat /etc/crontab 2>/dev/null || true; echo "# cron dirs"; ls -la /etc/cron* 2>/dev/null || true; echo "# spool"; ls -la /var/spool/cron /var/spool/cron/crontabs 2>/dev/null || true'
  incus_exec "$c" "$CDIR/users-ssh.txt" 'getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true; echo; find /root /home -maxdepth 3 -name authorized_keys -type f -exec sh -c "echo === {}; wc -l {}; sed -n 1,20p {}" \; 2>/dev/null || true'
  incus_exec "$c" "$CDIR/tmp-executables.txt" 'find /tmp /var/tmp /dev/shm -xdev -maxdepth 3 -type f \( -perm -111 -o -name "*.sh" -o -name "*.py" \) -ls 2>/dev/null | head -n 300 || true'
  incus_exec "$c" "$CDIR/suspicious-paths.txt" 'find /opt /usr/local /etc/systemd/system /etc/init.d -maxdepth 4 -type f 2>/dev/null | egrep -i "x-ui|3x-ui|s-ui|v2board|sspanel|trojan|xray|v2ray|sing-box|hysteria|tuic|frp|gost|cloudflared|ngrok|xmrig|masscan|zmap|hping|hydra|kinsing|kdevtmpfsi|sub|subscribe" | head -n 500 || true'
  incus_exec "$c" "$CDIR/docker-if-any.txt" 'docker ps -a 2>/dev/null || true; echo; docker network ls 2>/dev/null || true; echo; podman ps -a 2>/dev/null || true'

  # 关键词命中
  {
    echo "# suspicious process/listen/service/path keyword hits"
    grep -Eai "$SUSPICIOUS_RE" "$CDIR/processes-full.txt" "$CDIR/listening-ports.txt" "$CDIR/systemd-services.txt" "$CDIR/suspicious-paths.txt" 2>/dev/null || true
    echo
    echo "# panel/subscription keyword hits"
    grep -Eai "$PANEL_RE" "$CDIR/processes-full.txt" "$CDIR/listening-ports.txt" "$CDIR/systemd-services.txt" "$CDIR/suspicious-paths.txt" 2>/dev/null || true
  } > "$CDIR/keyword-hits.txt"

  # 按容器 IP 粗略统计连接
  {
    echo "# IPv4: $IPV4S"
    for ip in $IPV4S; do
      echo
      echo "## $ip conntrack summary"
      awk -v ip="$ip" '
        $0 ~ ip {
          total++
          if ($0 ~ /dport=25|dport=465|dport=587/) smtp++
          if ($0 ~ /dport=22|dport=23|dport=445|dport=3389|dport=6379|dport=9200|dport=2375|dport=2376/) risky++
          if (match($0, /dst=([0-9.]+)/, m)) dst[m[1]]=1
          if (match($0, /src=([0-9.]+)/, m)) src[m[1]]=1
          if (match($0, /dport=([0-9]+)/, m)) dport[m[1]]++
        }
        END {
          for (x in src) sc++; for (x in dst) dc++;
          printf("conntrack_lines=%d\nunique_src_seen=%d\nunique_dst_seen=%d\nsmtp_hits=%d\nrisky_port_hits=%d\n", total+0, sc+0, dc+0, smtp+0, risky+0)
          print "top_dports:";
          for (p in dport) print dport[p], p
        }' "$OUTDIR/host/conntrack-full.txt" | sort -nr 2>/dev/null | head -n 80 || true
      echo
      echo "## $ip conntrack lines sample"
      grep -F "$ip" "$OUTDIR/host/conntrack-full.txt" 2>/dev/null | head -n 1000 || true
      echo
      echo "## $ip ss lines sample"
      grep -F "$ip" "$OUTDIR/host/ss-full.txt" 2>/dev/null | head -n 1000 || true
      echo
      echo "## $ip high-risk ports hits"
      grep -F "$ip" "$OUTDIR/host/conntrack-full.txt" 2>/dev/null | grep -E "$SCAN_PORT_RE" | head -n 300 || true
    done
  } > "$CDIR/host-connection-attribution.txt"

  # 单容器摘要
  {
    echo "container=$c"
    echo "ipv4=$IPV4S"
    echo "privileged=$(incus config get "$c" security.privileged 2>/dev/null || true)"
    echo "nesting=$(incus config get "$c" security.nesting 2>/dev/null || true)"
    echo "raw.lxc=$(incus config get "$c" raw.lxc 2>/dev/null | tr '\n' ' ' || true)"
    echo "raw.idmap=$(incus config get "$c" raw.idmap 2>/dev/null | tr '\n' ' ' || true)"
    echo "keyword_hits=$(grep -Eai "$SUSPICIOUS_RE" "$CDIR/keyword-hits.txt" 2>/dev/null | wc -l || true)"
    echo "panel_hits=$(grep -Eai "$PANEL_RE" "$CDIR/keyword-hits.txt" 2>/dev/null | wc -l || true)"
    echo "listening_ports=$(grep -E 'LISTEN|udp|tcp' "$CDIR/listening-ports.txt" 2>/dev/null | wc -l || true)"
    echo "connections_sample=$(grep -E 'ESTAB|SYN|udp|tcp' "$CDIR/connections.txt" 2>/dev/null | wc -l || true)"
    echo "host_conntrack_lines=$(grep -F -f "$CDIR/ipv4.txt" "$OUTDIR/host/conntrack-full.txt" 2>/dev/null | wc -l || true)"
  } > "$CDIR/summary.env"

done < "$OUTDIR/container_names.txt"

# 总体风险摘要
{
  echo "# Incus Audit Summary"
  echo "time=$TS"
  echo "host=$HOST"
  echo
  echo "## Containers"
  cat "$OUTDIR/container_names.txt"
  echo
  echo "## Policy notes"
  echo "- 允许个人代理时，xray/sing-box/hysteria/tuic 等不是自动违规；要结合入站 IP 数、连接数、流量、面板/订阅痕迹判断。"
  echo "- 多人共享/机场化重点看：入站来源 IP 多、连接数长期高、多代理端口、x-ui/3x-ui/v2board/sspanel/订阅 API 痕迹、持续大流量。"
  echo "- SMTP 出站、扫描工具、挖矿、UDP/新建连接异常、高危端口爆破属于高危。"
  echo
  echo "## Per-container quick summary"
  for f in "$OUTDIR"/containers/*/summary.env; do
    [ -f "$f" ] || continue
    echo
    echo "### $(basename "$(dirname "$f")")"
    cat "$f"
  done
  echo
  echo "## Keyword hit files"
  for f in "$OUTDIR"/containers/*/keyword-hits.txt; do
    [ -f "$f" ] || continue
    hits=$(grep -Eai "$SUSPICIOUS_RE|$PANEL_RE" "$f" 2>/dev/null | wc -l || true)
    if [ "${hits:-0}" -gt 0 ]; then
      echo "- $(basename "$(dirname "$f")"): $hits hits -> $f"
    fi
  done
} > "$OUTDIR/README_SUMMARY.txt"

# 打包明文原始报告
TAR="${BASE}.tar.gz"
tar -C "$(dirname "$BASE")" -czf "$TAR" "$(basename "$BASE")"
sha256sum "$TAR" > "${TAR}.sha256"

# 生成脱敏报告包：便于直接发给 AI/他人审查
REDACT_BASE="${BASE}-redacted"
cp -a "$BASE" "$REDACT_BASE"
python3 - "$REDACT_BASE" <<'PY' || true
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
patterns = [
    (re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '<IPv4>'),
    (re.compile(r'([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}'), '<IPv6>'),
    (re.compile(r'(ssh-(?:rsa|ed25519)|ecdsa-sha2-nistp\d+)\s+[^\s]+(?:\s+[^\n]+)?'), '<SSH_PUBLIC_KEY>'),
    (re.compile(r'(?i)(password|passwd|token|secret|api[_-]?key|apikey|authorization|cookie|private[_-]?key)(\s*[:=]\s*)([^\s\n]+)'), r'\1\2<REDACTED>'),
]
for p in root.rglob('*'):
    if not p.is_file() or p.stat().st_size > 5_000_000:
        continue
    try:
        s = p.read_text(errors='ignore')
    except Exception:
        continue
    orig = s
    for rx, repl in patterns:
        s = rx.sub(repl, s)
    if s != orig:
        p.write_text(s)
PY
REDACT_TAR="${REDACT_BASE}.tar.gz"
tar -C "$(dirname "$REDACT_BASE")" -czf "$REDACT_TAR" "$(basename "$REDACT_BASE")"
sha256sum "$REDACT_TAR" > "${REDACT_TAR}.sha256"

if [ "${KEEP_RAW:-0}" != "1" ]; then
  rm -f "$TAR" "${TAR}.sha256"
  rm -rf "$BASE"
else
  log "明文报告包：$TAR"
  log "明文校验：${TAR}.sha256"
fi
rm -rf "$REDACT_BASE"

log "采集完成"
log "脱敏报告包：$REDACT_TAR"
log "脱敏校验：${REDACT_TAR}.sha256"
echo
echo "DONE: $REDACT_TAR"
echo "SHA256: $(cut -d' ' -f1 "${REDACT_TAR}.sha256")"
echo
echo "默认已脱敏 IPv4/IPv6/SSH 公钥/常见 token 字段，适合发给 AI 审查。若你需要保留原始 IP 用于精确归因，用 KEEP_RAW=1 重新运行并仅私下保存明文包。"
