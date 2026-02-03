#!/usr/bin/env bash
set -euo pipefail

# Secure Streamlit with oauth2-proxy
# Adds authentication annotations to the Streamlit Ingress
# Usage: ./secure.sh

# Version configuration (must match install.sh)
OAUTH2_PROXY_CHART_VERSION=10.1.2

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    GREEN=''
    BLUE=''
    NC=''
fi

echo -e "${BLUE}🔐 Securing Streamlit with oauth2-proxy...${NC}"
echo ""

# Upgrade oauth2-proxy to pick up any config changes (e.g., redirect_url)
echo "  Upgrading oauth2-proxy configuration..."
COOKIE_SECRET=$(kubectl get secret -n oauth2-proxy oauth2-proxy -o jsonpath='{.data.cookie-secret}' | base64 -d 2>/dev/null || openssl rand -base64 32 | tr -- '+/' '-_')
helm upgrade --install oauth2-proxy oauth2-proxy \
  --repo https://oauth2-proxy.github.io/manifests \
  --version "${OAUTH2_PROXY_CHART_VERSION}" \
  --namespace oauth2-proxy \
  --values k8s/oauth2-proxy-values.yaml \
  --set "config.cookieSecret=${COOKIE_SECRET}" \
  --wait

# Apply oauth2-proxy Ingress (handles /oauth2/* paths on the Streamlit host)
echo "  Applying oauth2-proxy Ingress..."
kubectl apply -f k8s/oauth2-proxy-ingress.yaml

# Add oauth2-proxy annotations to Streamlit Ingress
# auth-url: internal URL (used by ingress controller to verify auth)
# auth-signin: external URL (browser redirect for login)
echo "  Adding auth annotations to Streamlit Ingress..."
kubectl annotate ingress streamlit \
  --namespace default \
  --overwrite \
  nginx.ingress.kubernetes.io/auth-url='http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth' \
  nginx.ingress.kubernetes.io/auth-signin='https://streamlit.127.0.0.1.nip.io:30443/oauth2/start?rd=$escaped_request_uri' \
  nginx.ingress.kubernetes.io/auth-cache-key='$cookie__oauth2_proxy' \
  nginx.ingress.kubernetes.io/auth-cache-duration='200 201 401 1s'

echo -e "  ${GREEN}✅${NC} oauth2-proxy protection enabled"
echo ""
echo "Streamlit is now protected by Keycloak authentication."
echo "Access: https://streamlit.127.0.0.1.nip.io:30443"
echo ""
echo "Demo credentials (realm: streamlit):"
echo "  • demo / demo"
echo "  • demo2 / demo2 (group: beta-users)"
echo ""
