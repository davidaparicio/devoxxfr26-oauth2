#!/usr/bin/env bash
set -euo pipefail

# Secure Streamlit with Anubis (AI scraping protection)
# Deploys Anubis as a reverse proxy between the Streamlit Ingress and the
# Streamlit Service, so authenticated users also have to solve a JavaScript
# proof-of-work before reaching the app. Run AFTER ./secure.sh.
# Usage: ./anubis.sh

# Version configuration
ANUBIS_VERSION=v1.25.0

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

echo -e "${BLUE}🛡️  Adding Anubis (${ANUBIS_VERSION}) AI-scraping protection...${NC}"
echo ""

# Create / refresh the ED25519 signing key used by Anubis for challenge cookies.
# Reuse the existing secret if it is already there so repeated runs are idempotent.
echo "  Ensuring anubis-key Secret exists..."
if kubectl get secret anubis-key -n default >/dev/null 2>&1; then
    echo -e "    ${YELLOW}⚠️  Secret anubis-key already exists, keeping the existing key${NC}"
else
    KEY_HEX=$(openssl rand -hex 32)
    kubectl create secret generic anubis-key \
        --namespace default \
        --from-literal=ED25519_PRIVATE_KEY_HEX="${KEY_HEX}"
    echo -e "    ${GREEN}✅${NC} Secret created"
fi

# Apply the Anubis Deployment and Service.
echo "  Applying Anubis manifest..."
kubectl apply -f k8s/anubis.yaml
kubectl rollout status deployment/anubis --namespace default --timeout=120s
echo -e "    ${GREEN}✅${NC} Anubis deployed"

# Re-point the Streamlit Ingress backend to the Anubis Service.
# Same philosophy as secure.sh: mutate the live Ingress at runtime so the
# baseline YAML stays clean, and the step is trivially reversible.
echo "  Pointing Streamlit Ingress backend to the anubis Service..."
kubectl patch ingress streamlit \
    --namespace default \
    --type=json \
    -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"anubis"}]'

echo -e "  ${GREEN}✅${NC} Anubis protection enabled"
echo ""
echo "Streamlit is now behind Anubis proof-of-work challenges."
echo "Access: https://streamlit.127.0.0.1.nip.io:30443"
echo ""
echo "Smoke tests:"
echo "  • Browser (incognito): login with demo/demo, expect the 'Making sure"
echo "    you're not a bot' page before Streamlit loads."
echo "  • Scraper UA:"
echo "      curl -kL -A 'python-requests/2.31' https://streamlit.127.0.0.1.nip.io:30443/"
echo ""
echo "Rollback:"
echo "  kubectl patch ingress streamlit -n default --type=json \\"
echo "    -p='[{\"op\":\"replace\",\"path\":\"/spec/rules/0/http/paths/0/backend/service/name\",\"value\":\"streamlit\"}]'"
echo "  kubectl delete -f k8s/anubis.yaml"
echo ""
