#!/usr/bin/env bash
set -euo pipefail

# Deploy the Anubis static-site demo into the 'streamlit' kind cluster, exposed
# at https://devoxxfr26.127.0.0.1.nip.io:30443
#
# Reuses content from ./devoxxfr26/:
#   - www/          — static HTML + fonts, baked into a local nginx image
#   - botPolicy.yaml — Anubis bot-policy rules, mounted as a ConfigMap
#
# Requires ./install.sh to have been run (kind cluster + ingress-nginx +
# cert-manager + selfsigned-issuer ClusterIssuer).
#
# Usage: ./devoxxfr26.sh [--clean]

ANUBIS_VERSION=v1.25.0
CLUSTER_NAME="streamlit"
NAMESPACE="devoxxfr26"
HOST="devoxxfr26.127.0.0.1.nip.io"
IMAGE="anubis-demo-nginx:local"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEMO_DIR="${SCRIPT_DIR}/devoxxfr26"
MANIFEST="${DEMO_DIR}/k8s/manifests-ingress.yaml"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

CLEAN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean) CLEAN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--clean]"
            echo ""
            echo "  --clean   Delete the ${NAMESPACE} namespace first (fresh deploy)"
            echo ""
            echo "Deploys the Anubis-protected static site from ./devoxxfr26/ into the"
            echo "streamlit kind cluster at https://${HOST}:30443"
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}❌ $1 is not installed: $2${NC}"
        exit 1
    fi
}

echo -e "${BLUE}🛡️  Deploying Anubis demo at https://${HOST}:30443${NC}"
echo ""

echo "🔍 Checking dependencies..."
check_dependency docker "https://docs.docker.com/get-docker/"
check_dependency kind "https://kind.sigs.k8s.io/"
check_dependency kubectl "https://kubernetes.io/docs/tasks/tools/"
echo -e "  ${GREEN}✅${NC} All dependencies installed"
echo ""

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo -e "${RED}❌ Kind cluster '${CLUSTER_NAME}' not found.${NC}"
    echo -e "   Run ${YELLOW}./install.sh${NC} first to create it."
    exit 1
fi

if ! kubectl get clusterissuer selfsigned-issuer >/dev/null 2>&1; then
    echo -e "${RED}❌ ClusterIssuer 'selfsigned-issuer' not found.${NC}"
    echo -e "   Run ${YELLOW}./install.sh${NC} first."
    exit 1
fi

if [[ "$CLEAN" == true ]]; then
    echo -e "${YELLOW}🧹 Deleting namespace ${NAMESPACE}...${NC}"
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true
    echo -e "  ${GREEN}✅${NC} Clean slate"
    echo ""
fi

# Build the nginx image with www/ baked in, then side-load it into the cluster
# (imagePullPolicy: Never in the manifest — we never push to a registry).
echo -e "${BLUE}🐳 Building nginx image ${IMAGE}...${NC}"
docker build -f "${DEMO_DIR}/k8s/Dockerfile.nginx" -t "${IMAGE}" "${DEMO_DIR}" >/dev/null
echo -e "  ${GREEN}✅${NC} Image built"

echo -e "${BLUE}📦 Loading image into kind cluster ${CLUSTER_NAME}...${NC}"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}" >/dev/null
echo -e "  ${GREEN}✅${NC} Image loaded"
echo ""

echo -e "${BLUE}📋 Creating namespace + anubis-policy ConfigMap...${NC}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap anubis-policy \
    --from-file=botPolicy.yaml="${DEMO_DIR}/botPolicy.yaml" \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
echo -e "  ${GREEN}✅${NC} Namespace + ConfigMap ready"
echo ""

echo -e "${BLUE}🚀 Applying manifests (nginx + anubis + Ingress)...${NC}"
kubectl apply -f "${MANIFEST}" --namespace "${NAMESPACE}"
# If the ConfigMap content changed between runs, roll anubis so it re-reads.
kubectl patch deployment anubis --namespace "${NAMESPACE}" --type=json \
    -p='[{"op":"replace","path":"/spec/template/metadata/annotations/demo~1policy-rev","value":"'"$(date +%s)"'"}]' \
    >/dev/null 2>&1 || true
kubectl rollout status deployment/nginx  --namespace "${NAMESPACE}" --timeout=120s
kubectl rollout status deployment/anubis --namespace "${NAMESPACE}" --timeout=120s
echo -e "  ${GREEN}✅${NC} Pods ready"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}🎉 Anubis demo deployed${NC}"
echo ""
echo "Traffic flow:"
echo "  Browser → ingress-nginx (TLS) → anubis (PoW challenge) → nginx (static site)"
echo ""
echo -e "Access:  ${BLUE}https://${HOST}:30443${NC}"
echo ""
echo "Smoke tests:"
echo "  • Browser (incognito): expect the 'Making sure you're not a bot' page"
echo "  • CLI allow-list: curl -kL -A 'curl/8' https://${HOST}:30443/"
echo "  • Scraper UA:     curl -kL -A 'Mozilla/5.0' https://${HOST}:30443/"
echo ""
echo "Inspect:"
echo "  kubectl get pods,svc,ingress -n ${NAMESPACE}"
echo "  kubectl logs -n ${NAMESPACE} -l app=anubis --tail=20"
echo ""
echo "Cleanup:"
echo "  kubectl delete namespace ${NAMESPACE}"
echo ""
