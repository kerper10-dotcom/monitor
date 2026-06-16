#!/bin/bash
# One-time Oracle API setup (5 min in browser, then terminal does the rest).
set -euo pipefail

export PATH="${HOME}/Library/Python/3.12/bin:${PATH}"

echo "Oracle server setup — API key (one browser step)"
echo "================================================"
echo ""
echo "In Oracle console (logged in):"
echo "  1. Top-right avatar → My profile"
echo "  2. Left: API keys → Add API key"
echo "  3. Generate API key pair → DOWNLOAD the .pem private key"
echo "  4. Copy the config preview (tenancy OCID, user OCID, region, fingerprint)"
echo ""
echo "Save the .pem to e.g. ~/.oci/oci_api_key.pem"
echo ""
read -r -p "Press Enter when the .pem is saved..."

pip3 install --user oci-cli -q 2>/dev/null || true
oci setup config

echo ""
echo "Test:"
oci iam region list --query 'data[0].name' --raw-output
echo ""
echo "If that printed a region name, run:"
echo "  cd \"$(cd "$(dirname "$0")/.." && pwd)\""
echo "  ./oracle/create-server.sh"