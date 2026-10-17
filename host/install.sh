#!/usr/bin/env bash
# Mele Host 一条命令安装（10-04）。在一台干净的 Ubuntu / Debian 服务器上用 root 跑：
#   curl -fsSL https://raw.githubusercontent.com/aporia-and-poros/mele-lite/main/host/install.sh | bash
# 可选：MELE_DOMAIN=你的域名（先把域名解析到这台服务器）；不填就用 sslip.io。
# 家里 / 学校的电脑、没有公网 IP（10-17）：MELE_TUNNEL=1，HTTPS 交给 Tailscale Funnel / Cloudflare Tunnel：
#   curl -fsSL …/install.sh | MELE_TUNNEL=1 MELE_DOMAIN=my-pc.tail1234.ts.net bash
#   （装了 Tailscale 并且登录了的话 MELE_DOMAIN 可以不填，自己读这台电脑的名字）
set -euo pipefail

# 整个包进函数、最后才调用（10-05）：`curl | bash` 是边下边读的，中间 docker compose exec 会把没读到的后半截脚本
# 当输入吃掉，模型下完脚本就悄悄结束了。包起来 = bash 先读完全文再跑。（函数体不缩进：里面的 heredoc 结束标记要顶格）
main() {

DIR=/opt/mele-host
RAW=${MELE_RAW:-https://raw.githubusercontent.com/aporia-and-poros/mele-lite/main/host}

say() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 跑（或者 sudo bash）"
[ "$(uname -s)" = Linux ] || die "只支持 Linux 服务器"

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 3500 ] || die "内存只有 ${mem_mb}MB，Mele Host 至少要 4GB（记忆模型要 2～3GB）"

# 4GB 的机器上记忆模型一加载就吃掉一半（10-04 实测峰值约 2GB）；没有交换区的话加 2GB 兜底，免得内存一紧进程被杀
if [ "$mem_mb" -lt 6000 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ] && [ ! -f /swapfile ]; then
  say "加 2GB 交换区（内存小于 6GB）"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if ! command -v docker >/dev/null 2>&1; then
  say "安装 Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "装好了 Docker 但没有 docker compose 插件"
command -v qrencode >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq qrencode >/dev/null || true; }

mkdir -p "$DIR" && cd "$DIR"
say "下载配置"
for f in docker-compose.yml Caddyfile mele-host; do curl -fsSL "$RAW/$f" -o "$f"; done
install -m 755 mele-host /usr/local/bin/mele-host

TUNNEL=${MELE_TUNNEL:-0}
if [ "$TUNNEL" = 1 ] && [ -z "${MELE_DOMAIN:-}" ] && command -v tailscale >/dev/null 2>&1; then
  MELE_DOMAIN=$(tailscale status --json 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
fi
[ "$TUNNEL" != 1 ] || [ -n "${MELE_DOMAIN:-}" ] || die "隧道模式要告诉我隧道给你的域名：MELE_TUNNEL=1 MELE_DOMAIN=my-pc.tail1234.ts.net"

if [ ! -f .env ]; then
  # 查公网 IP：一家查不到换下一家（10-12 内测：国内机器连不上 ipify，脚本停在这儿）
  ip=""
  [ "$TUNNEL" = 1 ] || for u in https://api.ipify.org https://ifconfig.me https://ip.sb https://4.ipw.cn; do
    ip=$(curl -fsS4 -m 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    ip=""
  done
  if [ -z "${MELE_DOMAIN:-}" ]; then
    [ -n "$ip" ] || die "拿不到公网 IP，请用 MELE_DOMAIN=你的域名 再跑一次"
    MELE_DOMAIN="${ip//./-}.sslip.io"
  fi
  rand() { openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '\n'; }
  cat > .env <<ENV
MELE_DOMAIN=$MELE_DOMAIN
MASTER_KEY=$(rand 32)
SECRET=$(rand 48)
DB_PASSWORD=$(openssl rand -hex 24)
RERANK=0
ENV
  chmod 600 .env
fi
# 隧道模式在第一次起之前就写进 .env：不然 Caddy 先去抢 80 / 443，家里电脑上这俩端口常被占，一起就失败
if [ "$TUNNEL" = 1 ]; then
  for kv in "MELE_DOMAIN=$MELE_DOMAIN" "MELE_SITE=:80" "MELE_HTTP_PORT=127.0.0.1:${MELE_TUNNEL_PORT:-8080}" \
            "MELE_HTTPS_PORT=127.0.0.1:$(( ${MELE_TUNNEL_PORT:-8080} + 363 ))"; do
    k=${kv%%=*}
    if grep -q "^$k=" .env; then sed -i "s|^$k=.*|$kv|" .env; else echo "$kv" >> .env; fi
  done
fi
set -a; . ./.env; set +a

say "启动（第一次要下载镜像，几分钟）"
docker compose pull --ignore-pull-failures
docker compose up -d

say "下载记忆模型（约 2.3GB，只这一次）"
docker compose exec -T mele python -m api.host warm </dev/null

if [ "${MELE_SITE:-}" = ":80" ]; then
  say "隧道模式"
  mele-host tunnel on "$MELE_DOMAIN" </dev/null
else
  say "等 HTTPS 证书"
  for _ in $(seq 1 60); do
    curl -fsS "https://$MELE_DOMAIN/version" >/dev/null 2>&1 && break
    sleep 5
  done
  curl -fsS "https://$MELE_DOMAIN/version" >/dev/null || die "https://$MELE_DOMAIN 连不上：检查防火墙 80 / 443 端口有没有开（家里 / 学校的电脑没有公网 IP 的话，用隧道模式：MELE_TUNNEL=1）"
fi

mele-host pair </dev/null

cat <<DONE

✅ 装好了：https://$MELE_DOMAIN

⚠️  主密钥（加密你存在服务器上的模型 key，丢了就全解不开）——现在就抄一份放安全的地方：
    $MASTER_KEY
    以后随时看：mele-host key

常用：mele-host pair（重新配对）· mele-host update（升级）· mele-host logs（看日志）· mele-host tunnel（隧道模式）
想让别的 AI（比如 Claude）也连上 TA 的记忆：App 里 TA 设定 → 记性 →「让别的 AI 连上 TA 的记忆」
DONE
}

main "$@"
