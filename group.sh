#!/usr/bin/env bash
set -euo pipefail

# Restrict Streamlit access to beta-users group only
# Usage: ./group.sh

# Version configuration (must match install.sh)
OAUTH2_PROXY_CHART_VERSION=10.1.2

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    GREEN=''
    BLUE=''
    YELLOW=''
    NC=''
fi

echo -e "${BLUE}🔒 Restricting access to beta-users group...${NC}"
echo ""

# Upgrade oauth2-proxy with group restriction
echo "  Upgrading oauth2-proxy with group restriction..."
COOKIE_SECRET=$(kubectl get secret -n oauth2-proxy oauth2-proxy -o jsonpath='{.data.cookie-secret}' | base64 -d 2>/dev/null || openssl rand -base64 32 | tr -- '+/' '-_')
helm upgrade --install oauth2-proxy oauth2-proxy \
  --repo https://oauth2-proxy.github.io/manifests \
  --version "${OAUTH2_PROXY_CHART_VERSION}" \
  --namespace oauth2-proxy \
  --values k8s/oauth2-proxy-values.yaml \
  --set "config.cookieSecret=${COOKIE_SECRET}" \
  --set "extraArgs.allowed-group=/beta-users" \
  --wait

# Apply oauth2-proxy Ingress
echo "  Applying oauth2-proxy Ingress..."
kubectl apply -f k8s/oauth2-proxy-ingress.yaml

# Add oauth2-proxy annotations to Streamlit Ingress
echo "  Adding auth annotations to Streamlit Ingress..."
kubectl annotate ingress streamlit \
  --namespace default \
  --overwrite \
  nginx.ingress.kubernetes.io/auth-url='http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth' \
  nginx.ingress.kubernetes.io/auth-signin='https://streamlit.127.0.0.1.nip.io:30443/oauth2/start?rd=$escaped_request_uri'

echo -e "  ${GREEN}✅${NC} Group restriction enabled"
echo ""
echo "Streamlit is now restricted to beta-users group only."
echo "Access: https://streamlit.127.0.0.1.nip.io:30443"
echo ""
echo -e "${YELLOW}Access control:${NC}"
echo "  • demo / demo       → DENIED (not in beta-users)"
echo "  • demo2 / demo2     → ALLOWED (member of beta-users)"
echo ""
