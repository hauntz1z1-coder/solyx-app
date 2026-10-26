#!/usr/bin/env bash
# Cria o servidor de voz do SOLYX na Oracle Cloud (Always Free), pelo Cloud Shell:
#   rede própria, portas da voz liberadas e uma VM Ampere com Ubuntu 24.04.
# Pode rodar de novo sem problema: reaproveita o que já existe.
set -euo pipefail
C="${OCI_TENANCY:?Rode dentro do Cloud Shell da Oracle}"
q() { "$@" 2>/dev/null || true; }
say() { echo -e "\n==> $*"; }

say "Domínio de disponibilidade"
AD=$(oci iam availability-domain list -c "$C" --query 'data[0].name' --raw-output)
echo "    $AD"

say "Rede (VCN)"
VCN=$(q oci network vcn list -c "$C" --display-name solyx-vcn --lifecycle-state AVAILABLE --query 'data[0].id' --raw-output)
if [[ -z "$VCN" || "$VCN" == "None" ]]; then
  VCN=$(oci network vcn create -c "$C" --cidr-blocks '["10.0.0.0/16"]' --display-name solyx-vcn --dns-label solyxvcn --wait-for-state AVAILABLE --query 'data.id' --raw-output)
fi
echo "    $VCN"

say "Saída para a internet"
IGW=$(q oci network internet-gateway list -c "$C" --vcn-id "$VCN" --query 'data[0].id' --raw-output)
if [[ -z "$IGW" || "$IGW" == "None" ]]; then
  IGW=$(oci network internet-gateway create -c "$C" --vcn-id "$VCN" --is-enabled true --display-name solyx-igw --wait-for-state AVAILABLE --query 'data.id' --raw-output)
fi
RT=$(oci network vcn get --vcn-id "$VCN" --query 'data."default-route-table-id"' --raw-output)
oci network route-table update --rt-id "$RT" --force \
  --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null

say "Portas liberadas: TCP 22, 80, 443, 7881 | UDP 3478, 50000-60000"
SL=$(oci network vcn get --vcn-id "$VCN" --query 'data."default-security-list-id"' --raw-output)
tcp() { echo "{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"isStateless\":false,\"tcpOptions\":{\"destinationPortRange\":{\"min\":$1,\"max\":$2}}}"; }
udp() { echo "{\"source\":\"0.0.0.0/0\",\"protocol\":\"17\",\"isStateless\":false,\"udpOptions\":{\"destinationPortRange\":{\"min\":$1,\"max\":$2}}}"; }
oci network security-list update --security-list-id "$SL" --force \
  --ingress-security-rules "[$(tcp 22 22),$(tcp 80 80),$(tcp 443 443),$(tcp 7881 7881),$(udp 3478 3478),$(udp 50000 60000)]" \
  --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' >/dev/null

say "Sub-rede"
SUB=$(q oci network subnet list -c "$C" --vcn-id "$VCN" --display-name solyx-subnet --query 'data[0].id' --raw-output)
if [[ -z "$SUB" || "$SUB" == "None" ]]; then
  SUB=$(oci network subnet create -c "$C" --vcn-id "$VCN" --cidr-block 10.0.0.0/24 --display-name solyx-subnet --dns-label solyx --wait-for-state AVAILABLE --query 'data.id' --raw-output)
fi

say "Chave SSH (fica só no seu Cloud Shell: ~/.ssh/solyx)"
[[ -f ~/.ssh/solyx ]] || ssh-keygen -t ed25519 -f ~/.ssh/solyx -N "" -C solyx-voz >/dev/null

say "Imagem Ubuntu 24.04 (ARM)"
IMG=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output)
echo "    $IMG"

say "Servidor solyx-voz (Ampere A1, grátis)"
ID=$(q oci compute instance list -c "$C" --display-name solyx-voz --lifecycle-state RUNNING --query 'data[0].id' --raw-output)
if [[ -z "$ID" || "$ID" == "None" ]]; then
  for cfg in '4 24' '2 12' '1 6'; do
    set -- $cfg
    echo "    tentando $1 núcleos / $2 GB…"
    if ID=$(oci compute instance launch -c "$C" --availability-domain "$AD" --shape VM.Standard.A1.Flex \
        --shape-config "{\"ocpus\":$1,\"memoryInGBs\":$2}" --subnet-id "$SUB" --image-id "$IMG" --assign-public-ip true \
        --display-name solyx-voz --ssh-authorized-keys-file ~/.ssh/solyx.pub --boot-volume-size-in-gbs 50 \
        --wait-for-state RUNNING --query 'data.id' --raw-output 2>/tmp/solyx-launch.err); then break; fi
    ID=""
    grep -qi "capacity" /tmp/solyx-launch.err && { echo "    sem capacidade nesse tamanho"; continue; }
    cat /tmp/solyx-launch.err; exit 1
  done
  [[ -n "$ID" ]] || { echo "!! A Oracle está sem capacidade Ampere agora. Tente de novo em alguns minutos."; exit 1; }
fi

IP=$(oci compute instance list-vnics --instance-id "$ID" --query 'data[0]."public-ip"' --raw-output)
echo "$IP" > ~/solyx-ip.txt
echo
echo "✅ SERVIDOR PRONTO"
echo "   IP público: $IP"
echo "   Entrar:     ssh -i ~/.ssh/solyx ubuntu@$IP"
