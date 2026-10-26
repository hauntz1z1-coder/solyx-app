#!/usr/bin/env bash
# Instala o servidor de voz/vídeo do SOLYX (LiveKit) num servidor Ubuntu (ex.: Oracle Cloud Always Free).
#
#   Uso:  sudo bash instalar-livekit.sh livekit.bl4cksec.xyz
#
# Antes de rodar:
#   1. O domínio (registro A) precisa apontar para o IP público deste servidor
#      (no Cloudflare: nuvem CINZA, "DNS only"; o proxy laranja quebra a voz).
#   2. Na Oracle, a "Security List" da rede precisa liberar:
#      TCP 80, 443, 7881   e   UDP 3478, 50000-60000
#
# No fim ele mostra a URL, a API KEY e o API SECRET para colocar nos segredos do Supabase.
# O segredo fica só neste servidor (/opt/livekit/livekit.yaml) e no Supabase: não mande para ninguém.
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then echo "Uso: sudo bash $0 livekit.seudominio.com"; exit 1; fi
if [[ $EUID -ne 0 ]]; then echo "Rode com sudo."; exit 1; fi

LIVEKIT_IMAGE="livekit/livekit-server:v1.9.11"
CADDY_IMAGE="caddy:2.10-alpine"
DIR=/opt/livekit

echo "==> Esperando o servidor terminar de ligar"
cloud-init status --wait >/dev/null 2>&1 || true

echo "==> Conferindo o DNS de $DOMAIN"
MYIP="$(curl -fsS https://api.ipify.org || true)"
DNSIP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
echo "    IP deste servidor: ${MYIP:-?}   |   $DOMAIN aponta para: ${DNSIP:-nada}"
if [[ -n "$MYIP" && "$MYIP" != "$DNSIP" ]]; then
  echo "!!  O domínio ainda não aponta para este servidor. Ajuste o DNS (nuvem cinza) e rode de novo."
  exit 1
fi

# Servidor pequeno (1 GB): cria 2 GB de memória de troca para não faltar memória.
if [[ ! -f /swapfile ]] && (( $(awk '/MemTotal/{print $2}' /proc/meminfo) < 4000000 )); then
  echo "==> Criando 2 GB de swap"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> Instalando Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io docker-compose-v2 iptables-persistent openssl curl
systemctl enable --now docker

echo "==> Liberando as portas no firewall do Ubuntu (a imagem da Oracle bloqueia tudo por padrão)"
# Insere antes da regra REJECT que a Oracle coloca no fim da lista.
add_rule() {
  iptables -C INPUT "$@" -j ACCEPT 2>/dev/null && return
  local pos; pos="$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')"
  if [[ -n "$pos" ]]; then iptables -I INPUT "$pos" "$@" -j ACCEPT; else iptables -A INPUT "$@" -j ACCEPT; fi
}
add_rule -p tcp --dport 80
add_rule -p tcp --dport 443
add_rule -p tcp --dport 7881
add_rule -p udp --dport 3478
add_rule -p udp --dport 50000:60000
netfilter-persistent save

mkdir -p "$DIR/caddy-data"
cd "$DIR"

if [[ -f livekit.yaml ]]; then
  echo "==> Já existe $DIR/livekit.yaml: mantendo as chaves atuais"
  API_KEY="$(awk '/^keys:/{getline; sub(/^ +/,""); split($0,a,": "); print a[1]}' livekit.yaml)"
  API_SECRET="$(awk '/^keys:/{getline; sub(/^ +/,""); split($0,a,": "); print a[2]}' livekit.yaml)"
else
  API_KEY="API$(openssl rand -hex 6)"
  API_SECRET="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 44)"
fi

cat > livekit.yaml <<YAML
port: 7880
bind_addresses: [""]
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
turn:
  enabled: true
  udp_port: 3478
  domain: $DOMAIN
keys:
  $API_KEY: $API_SECRET
room:
  empty_timeout: 300
  departure_timeout: 20
logging:
  level: info
YAML
chmod 600 livekit.yaml

cat > Caddyfile <<CADDY
$DOMAIN {
  reverse_proxy 127.0.0.1:7880
}
CADDY

cat > docker-compose.yaml <<COMPOSE
services:
  livekit:
    image: $LIVEKIT_IMAGE
    command: --config /etc/livekit.yaml
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml:ro
  caddy:
    image: $CADDY_IMAGE
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
COMPOSE

echo "==> Subindo o LiveKit e o Caddy (certificado HTTPS automático)"
docker compose pull
docker compose up -d

echo "==> Esperando o certificado (até 90 s)"
for i in $(seq 1 30); do
  if curl -fsS "https://$DOMAIN" >/dev/null 2>&1; then OK=1; break; fi
  sleep 3
done

echo
if [[ "${OK:-}" == 1 ]]; then echo "✅ LiveKit no ar em https://$DOMAIN"; else echo "⚠️  O HTTPS ainda não respondeu. Veja: cd $DIR && docker compose logs caddy"; fi
echo
umask 077
printf 'LIVEKIT_URL=wss://%s\nLIVEKIT_API_KEY=%s\nLIVEKIT_API_SECRET=%s\n' "$DOMAIN" "$API_KEY" "$API_SECRET" > "$DIR/segredos-supabase.txt"
echo "Segredos para o Supabase salvos em $DIR/segredos-supabase.txt (não aparecem aqui de propósito)."
echo "  LIVEKIT_URL     = wss://$DOMAIN"
echo "  LIVEKIT_API_KEY = $API_KEY"
echo "  Para ver o secret:  sudo cat $DIR/segredos-supabase.txt"
