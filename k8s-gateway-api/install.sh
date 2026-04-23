#!/usr/bin/env bash
set -euo pipefail

# Gateway API stack — alternative to ../install.sh + ../secure.sh + ../anubis.sh
# Installs the full "final state" on a fresh Kind cluster using:
#   - Kubernetes Gateway API (instead of the Ingress API)
#   - NGINX Gateway Fabric (instead of ingress-nginx)
#   - oauth2-proxy in real reverse-proxy mode (instead of nginx auth-url subrequest)
# Usage: ./install.sh [--skip-cluster] [--clean] [--help]

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Versions
GATEWAY_API_VERSION=v1.2.1
NGF_CHART_VERSION=1.6.0
CERT_MANAGER_CHART_VERSION=v1.18.2
KEYCLOAKX_CHART_VERSION=7.1.7
KEYCLOAKX_APP_VERSION=26.5.1
OAUTH2_PROXY_CHART_VERSION=10.1.2
OAUTH2_PROXY_APP_VERSION=7.14.2
ANUBIS_VERSION=v1.25.0

CLUSTER_NAME="streamlit"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

SKIP_CLUSTER=false
CLEAN_INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cluster) SKIP_CLUSTER=true; shift ;;
        --clean) CLEAN_INSTALL=true; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-cluster   Skip Kind cluster creation (use existing cluster)"
            echo "  --clean          Delete existing cluster before creating new one"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Installs (on top of a Kind cluster):"
            echo "  - Gateway API ${GATEWAY_API_VERSION}"
            echo "  - NGINX Gateway Fabric ${NGF_CHART_VERSION}"
            echo "  - cert-manager ${CERT_MANAGER_CHART_VERSION}"
            echo "  - KeycloakX ${KEYCLOAKX_APP_VERSION} (chart ${KEYCLOAKX_CHART_VERSION})"
            echo "  - oauth2-proxy ${OAUTH2_PROXY_APP_VERSION} (reverse-proxy mode)"
            echo "  - Anubis ${ANUBIS_VERSION}"
            echo "  - Streamlit demo app"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}❌ $1 is not installed: $2${NC}"
        exit 1
    fi
}

echo -e "${BLUE}🔧 Gateway API stack installation${NC}"
echo "================================="
echo ""

echo "🔍 Checking dependencies..."
check_dependency "kind" "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
check_dependency "kubectl" "https://kubernetes.io/docs/tasks/tools/"
check_dependency "helm" "https://helm.sh/docs/intro/install/"
check_dependency "openssl" "https://www.openssl.org/source/"
echo -e "  ${GREEN}✅${NC} All dependencies installed"
echo ""

if [[ "$CLEAN_INSTALL" == true ]]; then
    echo -e "${YELLOW}🧹 Cleaning existing cluster...${NC}"
    kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
    echo -e "  ${GREEN}✅${NC} Cluster deleted"
    echo ""
fi

if [[ "$SKIP_CLUSTER" == false ]]; then
    echo -e "${BLUE}📦 Creating Kind cluster...${NC}"
    echo "  Cluster: ${CLUSTER_NAME}"
    echo "  Config: ${KIND_CONFIG}"

    if ! [[ -f "${KIND_CONFIG}" ]]; then
        echo -e "${RED}❌ Kind config not found at ${KIND_CONFIG}${NC}"
        exit 1
    fi

    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        echo -e "  ${YELLOW}⚠️  Cluster already exists (use --clean to recreate)${NC}"
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

# Gateway API CRDs must be installed before any GatewayClass controller
echo -e "${BLUE}📜 Installing Gateway API CRDs ${GATEWAY_API_VERSION}...${NC}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
echo -e "  ${GREEN}✅${NC} Gateway API CRDs installed"
echo ""

echo -e "${BLUE}🌐 Installing NGINX Gateway Fabric ${NGF_CHART_VERSION}...${NC}"
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version "${NGF_CHART_VERSION}" \
  --namespace nginx-gateway \
  --create-namespace \
  --values "${SCRIPT_DIR}/ngf-values.yaml" \
  --wait
echo -e "  ${GREEN}✅${NC} NGINX Gateway Fabric installed (GatewayClass: nginx)"
echo ""

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

echo -e "${BLUE}📋 Creating Keycloak realm ConfigMap...${NC}"
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keycloak-realm \
  --from-file=streamlit.json="${REPO_ROOT}/k8s/keycloak-realm.json" \
  --namespace keycloak \
  --dry-run=client -o yaml | kubectl apply -f -
echo -e "  ${GREEN}✅${NC} Realm ConfigMap created"
echo ""

echo -e "${BLUE}🔐 Installing KeycloakX ${KEYCLOAKX_CHART_VERSION} (appVersion ${KEYCLOAKX_APP_VERSION})...${NC}"
helm upgrade --install keycloakx keycloakx \
  --repo https://codecentric.github.io/helm-charts \
  --version "${KEYCLOAKX_CHART_VERSION}" \
  --namespace keycloak \
  --create-namespace \
  --values "${REPO_ROOT}/k8s/keycloakx-values.yaml" \
  --wait
echo -e "  ${GREEN}✅${NC} KeycloakX installed"
echo ""

echo -e "${BLUE}🚪 Applying Gateway + TLS certificates...${NC}"
kubectl apply -f "${SCRIPT_DIR}/gateway.yaml"
kubectl wait --for=condition=Ready certificate/keycloak-gateway-tls -n nginx-gateway --timeout=60s
kubectl wait --for=condition=Ready certificate/streamlit-gateway-tls -n nginx-gateway --timeout=60s
echo -e "  ${GREEN}✅${NC} Gateway + TLS ready"
echo ""

echo -e "${BLUE}🛣️  Applying Keycloak HTTPRoute...${NC}"
kubectl apply -f "${SCRIPT_DIR}/keycloak-httproute.yaml"
echo -e "  ${GREEN}✅${NC} https://keycloak.127.0.0.1.nip.io:30443"
echo ""

echo -e "${BLUE}🚀 Deploying Streamlit...${NC}"
kubectl apply -f "${SCRIPT_DIR}/streamlit.yaml"
kubectl rollout status deployment/streamlit --namespace default --timeout=120s
echo -e "  ${GREEN}✅${NC} Streamlit deployed"
echo ""

echo -e "${BLUE}🛡️  Deploying Anubis ${ANUBIS_VERSION} (in front of Streamlit)...${NC}"
if ! kubectl get secret anubis-key -n default >/dev/null 2>&1; then
    kubectl create secret generic anubis-key \
        --namespace default \
        --from-literal=ED25519_PRIVATE_KEY_HEX="$(openssl rand -hex 32)"
fi
kubectl apply -f "${REPO_ROOT}/k8s/anubis-policy.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/anubis.yaml"
kubectl rollout status deployment/anubis --namespace default --timeout=120s
echo -e "  ${GREEN}✅${NC} Anubis deployed (upstream: streamlit)"
echo ""

echo -e "${BLUE}🛡️  Installing oauth2-proxy ${OAUTH2_PROXY_APP_VERSION} (reverse-proxy mode)...${NC}"
COOKIE_SECRET=$(openssl rand -base64 32 | tr -- '+/' '-_')
helm upgrade --install oauth2-proxy oauth2-proxy \
  --repo https://oauth2-proxy.github.io/manifests \
  --version "${OAUTH2_PROXY_CHART_VERSION}" \
  --namespace oauth2-proxy \
  --create-namespace \
  --values "${SCRIPT_DIR}/oauth2-proxy-values.yaml" \
  --set "config.cookieSecret=${COOKIE_SECRET}" \
  --wait
echo -e "  ${GREEN}✅${NC} oauth2-proxy installed (upstream: anubis → streamlit)"
echo ""

echo -e "${BLUE}🛣️  Applying Streamlit HTTPRoute...${NC}"
kubectl apply -f "${SCRIPT_DIR}/streamlit-httproute.yaml"
echo -e "  ${GREEN}✅${NC} https://streamlit.127.0.0.1.nip.io:30443"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}🎉 Gateway API stack ready!${NC}"
echo ""
echo "Traffic flow:"
echo "  Browser → NGF Gateway (HTTPS) → oauth2-proxy → anubis → streamlit"
echo ""
echo "Access:"
echo -e "  ${BLUE}Keycloak:${NC}  https://keycloak.127.0.0.1.nip.io:30443 (admin/admin)"
echo -e "  ${BLUE}Streamlit:${NC} https://streamlit.127.0.0.1.nip.io:30443 (demo/demo or demo2/demo2)"
echo ""
echo "Inspect:"
echo "  kubectl get gateway -A"
echo "  kubectl get httproute -A"
echo "  kubectl describe gateway demo -n nginx-gateway"
echo ""
echo "Cleanup:"
echo "  kind delete cluster --name ${CLUSTER_NAME}"
echo ""
