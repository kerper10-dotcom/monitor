#!/bin/bash
# Create Oracle VM from terminal (skips broken console UI), then deploy both bots.
# Prerequisite: run `oci setup config` once (API key from Oracle profile).
set -euo pipefail

export PATH="${HOME}/Library/Python/3.12/bin:${PATH}"
command -v oci >/dev/null || { echo "Run: pip3 install --user oci-cli"; exit 1; }
[[ -f "${HOME}/.oci/config" ]] || { echo "Run first: oci setup config"; exit 1; }

REGION="${OCI_REGION:-eu-turin-1}"
export OCI_CLI_REGION="$REGION"
VCN_ID="${OCI_VCN_ID:-ocid1.vcn.oc1.eu-turin-1.amaaaaaaf5mmyvaaocjg7i7odo2xqtvnl4kwmlhmjz3x3sb7pwadw32autua}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/oracle_njuskalo.pub}"
INSTANCE_NAME="${INSTANCE_NAME:-njuskalo-bots}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SSH_KEY" ]] || { echo "Missing SSH public key: $SSH_KEY"; exit 1; }

COMPARTMENT="$(awk -F= '/^tenancy=/{print $2}' "$HOME/.oci/config" | tr -d ' ')"
[[ -n "$COMPARTMENT" ]] || { echo "Could not read tenancy from ~/.oci/config"; exit 1; }

echo "==> Region: $REGION"
echo "==> Compartment: $COMPARTMENT"
echo "==> VCN: $VCN_ID"

pick_subnet() {
  local subnets json count i access cidr id name
  json="$(oci network subnet list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all)"
  count="$(echo "$json" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))")"
  if [[ "$count" -gt 0 ]]; then
    for i in $(seq 0 $((count - 1))); do
      access="$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin)['data'][$i]; print('public' if d.get('prohibit-public-ip-on-vnic')==False else 'private')")"
      cidr="$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][$i]['cidr-block'])")"
      id="$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][$i]['id'])")"
      name="$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][$i]['display-name'])")"
      echo "   Found subnet: $name ($cidr) — $access"
      if [[ "$access" == "public" ]]; then
        echo "$id"
        return 0
      fi
    done
    echo "   No public subnet in list; will create one."
  fi
  return 1
}

SUBNET_ID="$(pick_subnet || true)"

if [[ -z "${SUBNET_ID:-}" ]]; then
  echo "==> Creating public subnet..."
  RT_ID="$(oci network route-table list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(next((x['id'] for x in d if 'Default' in x.get('display-name','')), d[0]['id']))")"
  SL_ID="$(oci network security-list list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(next((x['id'] for x in d if 'Default' in x.get('display-name','')), d[0]['id']))")"
  VCN_CIDR="$(oci network vcn get --vcn-id "$VCN_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['cidr-blocks'][0])")"
  SUBNET_CIDR="$VCN_CIDR"
  SUBNET_ID="$(oci network subnet create \
    --compartment-id "$COMPARTMENT" \
    --vcn-id "$VCN_ID" \
    --cidr-block "$SUBNET_CIDR" \
    --display-name "public-subnet" \
    --prohibit-public-ip-on-vnic false \
    --route-table-id "$RT_ID" \
    --security-list-id "$SL_ID" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"
  echo "   Created subnet: $SUBNET_ID"
fi

echo "==> Ensuring SSH (port 22) on security list..."
SL_ID="$(oci network subnet get --subnet-id "$SUBNET_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['security-list-ids'][0])")"
HAS_SSH="$(oci network security-list get --security-list-id "$SL_ID" \
  | python3 -c "import sys,json; rules=json.load(sys.stdin)['data'].get('ingress-security-rules',[]); print('yes' if any(r.get('tcp-options',{}).get('destination-port-range',{}).get('min')==22 for r in rules) else 'no')")"
if [[ "$HAS_SSH" != "yes" ]]; then
  oci network security-list update --security-list-id "$SL_ID" --force \
    --ingress-security-rules "[{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"is-stateless\":false,\"tcp-options\":{\"destination-port-range\":{\"min\":22,\"max\":22}}}]" \
    >/dev/null
  echo "   Added TCP 22 ingress."
else
  echo "   Port 22 already open."
fi

AD="$(oci iam availability-domain list --compartment-id "$COMPARTMENT" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['name'])")"
echo "==> Availability domain: $AD"

launch_with_shape() {
  local shape="$1" image_id="$2" extra_args=("${@:3}")
  oci compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$COMPARTMENT" \
    --display-name "$INSTANCE_NAME" \
    --shape "$shape" \
    --image-id "$image_id" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_KEY" \
    "${extra_args[@]}" \
    --wait-for-state RUNNING \
    --query 'data.id' --raw-output
}

echo "==> Resolving Ubuntu 22.04 image..."
try_shapes=(
  "VM.Standard.E2.1.Micro"
  "VM.Standard.A1.Flex"
)

INSTANCE_ID=""
for shape in "${try_shapes[@]}"; do
  echo "   Trying shape: $shape"
  if [[ "$shape" == "VM.Standard.A1.Flex" ]]; then
    IMAGE_ID="$(oci compute image list --compartment-id "$COMPARTMENT" \
      --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
      --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --all \
      | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")"
    [[ -n "$IMAGE_ID" ]] || continue
    if INSTANCE_ID="$(launch_with_shape "$shape" "$IMAGE_ID" --shape-config '{"ocpus":1,"memoryInGBs":6}' 2>/tmp/oci-launch.err)"; then
      break
    fi
    echo "   Failed: $(tail -1 /tmp/oci-launch.err)"
  else
    IMAGE_ID="$(oci compute image list --compartment-id "$COMPARTMENT" \
      --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
      --shape "VM.Standard.E2.1.Micro" --sort-by TIMECREATED --all \
      | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")"
    [[ -n "$IMAGE_ID" ]] || continue
    if INSTANCE_ID="$(launch_with_shape "$shape" "$IMAGE_ID" 2>/tmp/oci-launch.err)"; then
      break
    fi
    echo "   Failed: $(tail -1 /tmp/oci-launch.err)"
  fi
  INSTANCE_ID=""
done

[[ -n "$INSTANCE_ID" ]] || { echo "ERROR: Could not create instance (usually out of capacity). Try again later or another AD."; exit 1; }

PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
  | python3 -c "import sys,json; vnics=json.load(sys.stdin)['data'];
for v in vnics:
  for ip in v.get('public-ip',[]) or []:
    pass
print(vnics[0].get('public-ip') or '')")"

if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0].\"public-ip\"' --raw-output 2>/dev/null || true)"
fi

echo ""
echo "==> VM RUNNING"
echo "    Instance: $INSTANCE_ID"
echo "    Public IP: $PUBLIC_IP"
echo ""

if [[ -n "$PUBLIC_IP" ]]; then
  echo "==> Deploying bots..."
  "$SCRIPT_DIR/deploy-from-mac.sh" "$PUBLIC_IP"
else
  echo "WARN: No public IP yet. Check Oracle console, then run:"
  echo "  $SCRIPT_DIR/deploy-from-mac.sh <PUBLIC_IP>"
fi