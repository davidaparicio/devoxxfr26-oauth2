#!/usr/bin/env bash
set -euo pipefail

# Demonstrate Kyverno ENFORCED policy — applied to every Ingress in the default
# namespace, with no opt-out label. Whereas kyverno.sh shows an opt-in policy
# (only Ingresses labeled oauth2-proxy=enabled get mutated), this script shows
# the same machinery but impossible to bypass: a plain vanilla Ingress with
# zero labels and zero auth annotations still gets protected.
# Usage: ./enforced.sh

KYVERNO_CHART_VERSION=3.3.4

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN=''; BLUE=''; YELLOW=''; RED=''; NC=''
fi

echo -e "${BLUE}🛡️ Kyverno ENFORCED Policy Demo${NC}"
echo ""

# Step 1: Install Kyverno (idempotent — skips if already present)
echo -e "${BLUE}1. Ensuring Kyverno ${KYVERNO_CHART_VERSION} is installed...${NC}"
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
echo -e "   ${GREEN}✅${NC} Kyverno ready"
echo ""

# Step 2: Apply the enforced policy
echo -e "${BLUE}2. Applying enforced Kyverno policy (no label selector)...${NC}"
kubectl apply -f k8s/kyverno-oauth2-policy-enforced.yaml
kubectl wait --for=condition=ready clusterpolicy enforce-oauth2-proxy-auth --timeout=60s
sleep 2
echo -e "   ${GREEN}✅${NC} Policy active: every Ingress in default ns will be mutated"
echo ""

# Step 3: Delete the existing Streamlit Ingress
echo -e "${BLUE}3. Deleting existing Streamlit Ingress...${NC}"
kubectl delete ingress streamlit -n default --ignore-not-found
echo -e "   ${GREEN}✅${NC} Ingress deleted"
echo ""

# Step 4: Re-apply the vanilla Streamlit Ingress from k8s/streamlit.yaml.
# This manifest has no 'oauth2-proxy: enabled' label and no auth-url /
# auth-signin annotations — it's the same Ingress a new developer might write
# without knowing about oauth2-proxy.
echo -e "${BLUE}4. Applying vanilla Streamlit Ingress (no label, no auth annotations)...${NC}"
echo -e "   ${YELLOW}Ingress spec being applied:${NC}"
awk '/^kind: Ingress/,/^---$|^$/' k8s/streamlit.yaml | sed 's/^/   /'
echo ""
kubectl apply -f k8s/streamlit.yaml
echo -e "   ${GREEN}✅${NC} Ingress applied"
echo ""

# Step 5: Show what Kyverno injected
echo -e "${BLUE}5. Annotations on the Streamlit Ingress after Kyverno mutation:${NC}"
sleep 2
kubectl get ingress streamlit -n default -o jsonpath='{.metadata.annotations}' \
    | jq -r 'to_entries[] | "   • \(.key): \(.value)"'
echo ""

if kubectl get ingress streamlit -n default -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/auth-url}' | grep -q "oauth2-proxy"; then
    echo -e "   ${GREEN}✅ ENFORCED${NC} — a plain Ingress with zero labels was still protected"
else
    echo -e "   ${RED}❌ FAILED${NC} — annotations not injected; check kyverno:"
    echo "      kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller"
fi
echo ""

# Step 6: Demonstrate that even a fresh, unrelated Ingress gets caught
echo -e "${BLUE}6. Proof: create a brand-new Ingress with a different name, no labels...${NC}"
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-enforced
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: demo.127.0.0.1.nip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: streamlit
            port:
              number: 80
EOF
sleep 2
echo ""
echo -e "   ${YELLOW}Annotations on demo-enforced:${NC}"
kubectl get ingress demo-enforced -n default -o jsonpath='{.metadata.annotations}' \
    | jq -r 'to_entries[] | "   • \(.key): \(.value)"' 2>/dev/null || echo "   (none)"
echo ""
kubectl delete ingress demo-enforced -n default >/dev/null 2>&1
echo -e "   ${GREEN}✅${NC} demo-enforced cleaned up"
echo ""

echo -e "${GREEN}Demo complete!${NC}"
echo ""
echo "Key difference vs. ./kyverno.sh:"
echo "  • kyverno.sh  → label-based (opt-in)  — devs can forget the label"
echo "  • enforced.sh → namespace-wide         — zero opt-out, fail-closed security"
echo ""
echo "Useful commands:"
echo "  • View policy:     kubectl get clusterpolicy enforce-oauth2-proxy-auth -o yaml"
echo "  • Policy reports:  kubectl get polr -A"
echo "  • Kyverno logs:    kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller"
echo ""
