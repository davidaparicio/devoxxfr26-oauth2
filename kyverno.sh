#!/usr/bin/env bash
set -euo pipefail

# Demonstrate Kyverno automatic policy enforcement for oauth2-proxy
# This script:
# 1. Installs Kyverno via Helm
# 2. Creates a policy that auto-adds oauth2-proxy annotations
# 3. Removes the existing annotated ingress
# 4. Re-applies ingress WITHOUT annotations
# 5. Shows that Kyverno added them automatically
#
# Usage: ./kyverno.sh

# Version configuration
KYVERNO_CHART_VERSION=3.3.4

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m' # No Color
else
    GREEN=''
    BLUE=''
    YELLOW=''
    RED=''
    NC=''
fi

echo -e "${BLUE}🛡️ Kyverno Policy Enforcement Demo${NC}"
echo ""

# Step 1: Install Kyverno
echo -e "${BLUE}1. Installing Kyverno ${KYVERNO_CHART_VERSION}...${NC}"
helm upgrade --install kyverno kyverno \
  --repo https://kyverno.github.io/kyverno \
  --version "${KYVERNO_CHART_VERSION}" \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --wait
echo -e "   ${GREEN}✅${NC} Kyverno installed"
echo ""

# Step 2: Apply the oauth2-proxy policy
echo -e "${BLUE}2. Creating Kyverno policy for oauth2-proxy annotations...${NC}"
kubectl apply -f k8s/kyverno-oauth2-policy.yaml
echo -e "   ${GREEN}✅${NC} Policy created"
echo ""

# Wait for policy to be ready
echo "   Waiting for policy to be ready..."
sleep 3

# Step 3: Show current ingress state
echo -e "${BLUE}3. Current Streamlit Ingress annotations:${NC}"
echo -e "   ${YELLOW}(These were added manually or by secure.sh)${NC}"
kubectl get ingress streamlit -n default -o jsonpath='{.metadata.annotations}' | jq -r 'to_entries[] | "   • \(.key): \(.value)"' 2>/dev/null || echo "   (no ingress found)"
echo ""

# Step 4: Delete the existing ingress
echo -e "${BLUE}4. Deleting existing Streamlit Ingress...${NC}"
kubectl delete ingress streamlit -n default --ignore-not-found
echo -e "   ${GREEN}✅${NC} Ingress deleted"
echo ""

# Step 5: Apply ingress WITHOUT auth annotations (but WITH the label)
echo -e "${BLUE}5. Applying Streamlit Ingress WITHOUT auth annotations...${NC}"
echo -e "   ${YELLOW}(Only has label 'oauth2-proxy: enabled')${NC}"
echo ""
echo "   Ingress YAML being applied:"
echo -e "   ${YELLOW}---${NC}"
grep -A 5 "annotations:" k8s/streamlit-ingress-kyverno.yaml | head -6 | sed 's/^/   /'
echo -e "   ${YELLOW}---${NC}"
echo ""
kubectl apply -f k8s/streamlit-ingress-kyverno.yaml
echo -e "   ${GREEN}✅${NC} Ingress applied"
echo ""

# Step 6: Show that Kyverno added the annotations
echo -e "${BLUE}6. Verifying Kyverno added the annotations automatically:${NC}"
sleep 2  # Give Kyverno a moment to mutate

echo ""
echo "   Current annotations on Streamlit Ingress:"
kubectl get ingress streamlit -n default -o jsonpath='{.metadata.annotations}' | jq -r 'to_entries[] | "   • \(.key): \(.value)"'
echo ""

# Check if auth annotations are present
if kubectl get ingress streamlit -n default -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/auth-url}' | grep -q "oauth2-proxy"; then
    echo -e "   ${GREEN}✅ SUCCESS!${NC} Kyverno automatically added oauth2-proxy annotations!"
else
    echo -e "   ${RED}❌ FAILED:${NC} Annotations not found. Check Kyverno logs:"
    echo "      kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller"
fi
echo ""

# Show policy status
echo -e "${BLUE}7. Policy Status:${NC}"
kubectl get clusterpolicy add-oauth2-proxy-auth -o jsonpath='   Name: {.metadata.name}{"\n"}   Ready: {.status.ready}{"\n"}'
echo ""

echo -e "${GREEN}Demo complete!${NC}"
echo ""
echo "Useful commands:"
echo "  • View policy:     kubectl get clusterpolicy add-oauth2-proxy-auth -o yaml"
echo "  • View ingress:    kubectl get ingress streamlit -n default -o yaml"
echo "  • Kyverno logs:    kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller"
echo ""
