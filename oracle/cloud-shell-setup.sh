#!/bin/bash
# Run this in ORACLE CLOUD SHELL (browser terminal) — already logged in, no API key needed.
set -euo pipefail

REGION="eu-turin-1"
VCN_ID="ocid1.vcn.oc1.eu-turin-1.amaaaaaaf5mmyvaaocjg7i7odo2xqtvnl4kwmlhmjz3x3sb7pwadw32autua"
INSTANCE_NAME="njuskalo-bots"
SSH_PUB="${SSH_PUB:-}"

echo "==> Testing Cloud Shell auth..."
oci iam user list --query 'data[0].name' --raw-output

TENANCY="$(oci iam compartment list --query 'data[0].compartment-id' --raw-output 2>/dev/null || true)"
if [[ -z "$TENANCY" || "$TENANCY" != ocid1.tenancy* ]]; then
  TENANCY="$(grep -m1 '^tenancy=' ~/.oci/config | cut -d= -f2 | tr -d ' ')"
fi
echo "==> Tenancy/compartment: $TENANCY"

if [[ -z "$SSH_PUB" ]]; then
  echo "Paste your SSH PUBLIC key (ssh-ed25519 ...), then press Ctrl-D:"
  SSH_PUB="$(cat)"
fi

SUBNET_ID="$(oci network subnet list --compartment-id "$TENANCY" --vcn-id "$VCN_ID" --all \
  | python3 -c "import sys,json
subs=json.load(sys.stdin).get('data',[])
pub=[s for s in subs if s.get('prohibit-public-ip-on-vnic')==False]
print(pub[0]['id'] if pub else '')" 2>/dev/null || true)"

if [[ -z "$SUBNET_ID" ]]; then
  echo "==> Creating public subnet..."
  RT_ID="$(oci network route-table list --compartment-id "$TENANCY" --vcn-id "$VCN_ID" --all \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['id'])")"
  SL_ID="$(oci network security-list list --compartment-id "$TENANCY" --vcn-id "$VCN_ID" --all \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['id'])")"
  SUBNET_ID="$(oci network subnet create \
    --compartment-id "$TENANCY" --vcn-id "$VCN_ID" \
    --cidr-block 10.0.0.0/24 --display-name public-subnet \
    --prohibit-public-ip-on-vnic false \
    --route-table-id "$RT_ID" --security-list-id "$SL_ID" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
fi
echo "==> Subnet: $SUBNET_ID"

AD="$(oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[0].name' --raw-output)"
echo "==> AD: $AD"

echo "$SSH_PUB" > /tmp/njuskalo_ssh.pub
IMAGE_ID="$(oci compute image list --compartment-id "$TENANCY" \
  --operating-system 'Canonical Ubuntu' --operating-system-version '22.04' \
  --shape 'VM.Standard.E2.1.Micro' --sort-by TIMECREATED --all \
  --query 'data[0].id' --raw-output)"

echo "==> Launching VM (E2.1.Micro)..."
INSTANCE_ID="$(oci compute instance launch \
  --availability-domain "$AD" \
  --compartment-id "$TENANCY" \
  --display-name "$INSTANCE_NAME" \
  --shape 'VM.Standard.E2.1.Micro' \
  --image-id "$IMAGE_ID" \
  --subnet-id "$SUBNET_ID" \
  --assign-public-ip true \
  --ssh-authorized-keys-file /tmp/njuskalo_ssh.pub \
  --wait-for-state RUNNING \
  --query 'data.id' --raw-output)" || {
    echo "E2 failed, trying A1..."
    IMAGE_ID="$(oci compute image list --compartment-id "$TENANCY" \
      --operating-system 'Canonical Ubuntu' --operating-system-version '22.04' \
      --shape 'VM.Standard.A1.Flex' --sort-by TIMECREATED --all \
      --query 'data[0].id' --raw-output)"
    INSTANCE_ID="$(oci compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$TENANCY" \
      --display-name "$INSTANCE_NAME" \
      --shape 'VM.Standard.A1.Flex' \
      --shape-config '{"ocpus":1,"memoryInGBs":6}' \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --ssh-authorized-keys-file /tmp/njuskalo_ssh.pub \
      --wait-for-state RUNNING \
      --query 'data.id' --raw-output)"
  }

PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0].\"public-ip\"' --raw-output)"
echo ""
echo "============================================"
echo "VM READY"
echo "  Instance ID: $INSTANCE_ID"
echo "  PUBLIC IP:   $PUBLIC_IP"
echo "============================================"
echo "Send this IP back — bots will be deployed next."