#!/usr/bin/env bash
set -euo pipefail

# Keycloak Installation Script
# Creates a Kind cluster and installs 
# Usage: ./install.sh [--skip-cluster] [--clean] [--help]

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Version configuration
INGRESS_NGINX_VERSION=v1.14.2
CERT_MANAGER_CHART_VERSION=v1.18.2
KEYCLOAKX_CHART_VERSION=7.1.7
KEYCLOAKX_APP_VERSION=26.5.1
# oauth2-proxy (https://github.com/oauth2-proxy/oauth2-proxy)
OAUTH2_PROXY_CHART_VERSION=10.1.2
OAUTH2_PROXY_APP_VERSION=7.14.2
# anubis (https://github.com/TecharoHQ/anubis) — installed on demand by ./anubis.sh
ANUBIS_VERSION=v1.25.0

# Configuration
CLUSTER_NAME="streamlit"
KIND_CONFIG="k8s/kind-config.yaml"

# Parse command line arguments
SKIP_CLUSTER=false
CLEAN_INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cluster)
            SKIP_CLUSTER=true
            shift
            ;;
        --clean)
            CLEAN_INSTALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-cluster   Skip Kind cluster creation (use existing cluster)"
            echo "  --clean          Delete existing cluster before creating new one"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "What this script installs:"
            echo "  - Kind cluster (${CLUSTER_NAME})"
            echo "  - Ingress NGINX ${INGRESS_NGINX_VERSION}"
            echo "  - cert-manager ${CERT_MANAGER_CHART_VERSION}"
            echo "  - KeycloakX ${KEYCLOAKX_APP_VERSION} (chart ${KEYCLOAKX_CHART_VERSION})"
            echo "  - oauth2-proxy ${OAUTH2_PROXY_APP_VERSION} (chart ${OAUTH2_PROXY_CHART_VERSION})"
            echo ""
            echo "Credentials:"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check dependencies
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}❌ Error: $1 is not installed.${NC}"
        echo "   Please install it: $2"
        exit 1
    fi
}

echo -e "${BLUE}🔧 Keycloak Installation${NC}"
echo "================================"
echo ""

echo "🔍 Checking dependencies..."
check_dependency "kind" "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
check_dependency "kubectl" "https://kubernetes.io/docs/tasks/tools/"
check_dependency "helm" "https://helm.sh/docs/intro/install/"
check_dependency "openssl" "https://www.openssl.org/source/"
echo -e "  ${GREEN}✅${NC} All dependencies installed"
echo ""

# Clean install if requested
if [[ "$CLEAN_INSTALL" == true ]]; then
    echo -e "${YELLOW}🧹 Cleaning existing cluster...${NC}"
    kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
    echo -e "  ${GREEN}✅${NC} Cluster deleted"
    echo ""
fi

# Create Kind cluster
if [[ "$SKIP_CLUSTER" == false ]]; then
    echo -e "${BLUE}📦 Creating Kind cluster...${NC}"
    echo "  Cluster: ${CLUSTER_NAME}"
    echo "  Config: ${KIND_CONFIG}"

    if ! [[ -f "${KIND_CONFIG}" ]]; then
        echo -e "${RED}❌ Error: Kind config not found at ${KIND_CONFIG}${NC}"
        exit 1
    fi

    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        echo -e "  ${YELLOW}⚠️  Cluster already exists${NC}"
        echo "     Use --clean to delete and recreate"
    else
        kind create cluster --wait 120s --config "${KIND_CONFIG}" --name "${CLUSTER_NAME}"
        echo -e "  ${GREEN}✅${NC} Cluster created"
    fi

    kind export kubeconfig --name "${CLUSTER_NAME}"
    echo -e "  ${GREEN}✅${NC} Kubeconfig exported"
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping cluster creation${NC}"
    echo ""
fi

# Install Ingress NGINX
# Convert controller version (v1.x.x) to chart version (4.x.x)
INGRESS_NGINX_CHART_VERSION="${INGRESS_NGINX_VERSION/v1./4.}"
echo -e "${BLUE}🌐 Installing Ingress NGINX ${INGRESS_NGINX_VERSION} (chart ${INGRESS_NGINX_CHART_VERSION})...${NC}"
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --version "${INGRESS_NGINX_CHART_VERSION}" \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --wait
echo -e "  ${GREEN}✅${NC} Ingress NGINX installed"
echo ""

# Install cert-manager
echo -e "${BLUE}📜 Installing cert-manager ${CERT_MANAGER_CHART_VERSION}...${NC}"
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version "${CERT_MANAGER_CHART_VERSION}" \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
echo -e "  ${GREEN}✅${NC} cert-manager installed"
echo ""

# Create self-signed ClusterIssuer
echo -e "${BLUE}🔒 Creating self-signed ClusterIssuer...${NC}"
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
echo -e "  ${GREEN}✅${NC} ClusterIssuer created"
echo ""

# Create Keycloak realm ConfigMap
echo -e "${BLUE}📋 Creating Keycloak realm ConfigMap...${NC}"
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keycloak-realm \
  --from-file=streamlit.json=k8s/keycloak-realm.json \
  --namespace keycloak \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "  ${GREEN}✅${NC} Realm ConfigMap created"
echo ""

# Install KeycloakX
# helm repo add codecentric https://codecentric.github.io/helm-charts
echo -e "${BLUE}🔐 Installing KeycloakX ${KEYCLOAKX_CHART_VERSION} (appVersion ${KEYCLOAKX_APP_VERSION})...${NC}"
helm upgrade --install keycloakx keycloakx \
  --repo https://codecentric.github.io/helm-charts \
  --version "${KEYCLOAKX_CHART_VERSION}" \
  --namespace keycloak \
  --create-namespace \
  --values k8s/keycloakx-values.yaml \
  --wait
echo -e "  ${GREEN}✅${NC} KeycloakX installed"
echo ""

# Apply Keycloak Ingress
echo -e "${BLUE}🌐 Applying Keycloak Ingress...${NC}"
kubectl apply -f k8s/keycloak-ingress.yaml
echo -e "  ${GREEN}✅${NC} Keycloak Ingress applied (https://keycloak.127.0.0.1.nip.io)"
echo ""

# Install oauth2-proxy
echo -e "${BLUE}🛡️ Installing oauth2-proxy ${OAUTH2_PROXY_APP_VERSION} (chart ${OAUTH2_PROXY_CHART_VERSION})...${NC}"
COOKIE_SECRET=$(openssl rand -base64 32 | tr -- '+/' '-_')
helm upgrade --install oauth2-proxy oauth2-proxy \
  --repo https://oauth2-proxy.github.io/manifests \
  --version "${OAUTH2_PROXY_CHART_VERSION}" \
  --namespace oauth2-proxy \
  --create-namespace \
  --values k8s/oauth2-proxy-values.yaml \
  --set "config.cookieSecret=${COOKIE_SECRET}" \
  --wait
echo -e "  ${GREEN}✅${NC} oauth2-proxy installed"
echo ""

# Deploy Streamlit application
echo -e "${BLUE}🚀 Deploying Streamlit application...${NC}"
kubectl apply -f k8s/streamlit.yaml
kubectl rollout status deployment/streamlit --namespace default --timeout=120s
echo -e "  ${GREEN}✅${NC} Streamlit deployed"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}🎉 Setup Complete!${NC}"
echo ""
echo "Access Points:"
echo -e "  ${BLUE}Keycloak Admin:${NC}  https://keycloak.127.0.0.1.nip.io:30443 (admin/admin)"
echo -e "  ${BLUE}Streamlit App:${NC}   https://streamlit.127.0.0.1.nip.io:30443"
echo ""
echo "Demo Credentials:"
echo "  • Keycloak admin: admin / admin"
echo "  • Keycloak user:  demo / demo"
echo "  • Keycloak user:  demo2 / demo2 (group: beta-users)"
echo ""
echo "Next Steps (to enable oauth2-proxy protection):"
echo "  Add these annotations to the Streamlit Ingress:"
echo -e "     ${YELLOW}nginx.ingress.kubernetes.io/auth-url: http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth${NC}"
echo -e "     ${YELLOW}nginx.ingress.kubernetes.io/auth-signin: https://streamlit.127.0.0.1.nip.io:30443/oauth2/start?rd=\$escaped_request_uri${NC}"
echo ""
echo "Optional protection layers:"
echo -e "  • ${YELLOW}./secure.sh${NC}   Enable OAuth2 authentication"
echo -e "  • ${YELLOW}./kyverno.sh${NC}  Auto-inject auth annotations via a Kyverno policy"
echo -e "  • ${YELLOW}./anubis.sh${NC}   Add Anubis ${ANUBIS_VERSION} AI-scraping PoW challenge"
echo ""
echo "Useful Commands:"
echo "  • Check cluster: kubectl cluster-info --context kind-${CLUSTER_NAME}"
echo "  • Keycloak pods: kubectl get pods -n keycloak"
echo "  • Keycloak logs: kubectl logs -n keycloak -l app.kubernetes.io/name=keycloakx"
echo "  • oauth2-proxy logs: kubectl logs -n oauth2-proxy -l app.kubernetes.io/name=oauth2-proxy"
echo "  • Delete cluster: kind delete cluster --name ${CLUSTER_NAME}"
echo ""
