#!/usr/bin/env bash
set -uo pipefail

# Reproduces the oauth2-proxy "403 Unable to find a valid CSRF token" first-login
# race and verifies the cookie_csrf_per_request fix is active.
# Works against both k8s/ (nginx-ingress) and k8s-gateway-api/ (NGF) installs.
# Usage: ./test-csrf.sh [iterations]
#   iterations: number of sequential full-login attempts (default: 10)

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

STREAMLIT_URL="${STREAMLIT_URL:-https://streamlit.127.0.0.1.nip.io:30443}"
USERNAME="${USERNAME:-demo}"
PASSWORD="${PASSWORD:-demo}"
ITERATIONS="${1:-10}"

pass=0; fail=0
record() { if [[ "$1" == "pass" ]]; then pass=$((pass+1)); echo -e "  ${GREEN}✅${NC} $2"; else fail=$((fail+1)); echo -e "  ${RED}❌${NC} $2"; fi; }

echo -e "${BLUE}🧪 oauth2-proxy CSRF test${NC}"
echo "  Target: ${STREAMLIT_URL}"
echo "  User:   ${USERNAME}"
echo ""

# Preflight: endpoint is reachable
code=$(curl -sk -o /dev/null -w "%{http_code}" "${STREAMLIT_URL}/oauth2/start?rd=/")
if [[ "$code" != "302" ]]; then
    echo -e "${RED}❌ /oauth2/start returned HTTP ${code} (expected 302). Is the stack running?${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Test A — per-request CSRF cookie names
# Without the fix, every /oauth2/start writes a single "_oauth2_proxy_csrf"
# cookie, so concurrent flows overwrite each other. With cookie_csrf_per_request
# enabled, each /oauth2/start gets a unique name like "_oauth2_proxy_<hash>_csrf".
# -----------------------------------------------------------------------------
echo -e "${BLUE}Test A — per-request CSRF cookie names${NC}"
names=$(for i in 1 2 3; do
    curl -sk -D - -o /dev/null "${STREAMLIT_URL}/oauth2/start?rd=/" 2>/dev/null \
        | grep -i "^set-cookie:" | grep -oE "_oauth2_proxy_[A-Za-z0-9_-]*csrf" &
done; wait)
distinct=$(echo "$names" | sort -u | grep -c . || true)

if [[ "$distinct" -ge 3 ]]; then
    record pass "3 parallel /oauth2/start → ${distinct} distinct cookie names (fix active)"
    echo "$names" | sort -u | sed 's/^/      /'
elif [[ "$distinct" -eq 1 && $(echo "$names" | sort -u) == "_oauth2_proxy_csrf" ]]; then
    record fail "cookie_csrf_per_request is NOT enabled — all flows share _oauth2_proxy_csrf"
    echo -e "      ${YELLOW}Fix: add cookie_csrf_per_request = true to oauth2-proxy config${NC}"
else
    record fail "Unexpected cookie layout: ${distinct} distinct names"
    echo "$names" | sort -u | sed 's/^/      /'
fi
echo ""

# -----------------------------------------------------------------------------
# Helper: full OAuth2 login flow. Returns the HTTP code of the final page.
# -----------------------------------------------------------------------------
full_login() {
    local cookies; cookies=$(mktemp)
    local body form_action callback_url code

    # -L follows the redirect chain all the way to the Keycloak login form.
    # This handles both the upstream-proxy flow (GET / → 302 Keycloak, one hop)
    # and the auth-url/auth-signin flow (GET / → 302 /oauth2/start → 302
    # Keycloak, two hops) without branching on topology.
    body=$(curl -sk -L -b "$cookies" -c "$cookies" "${STREAMLIT_URL}/")
    form_action=$(echo "$body" | grep -oE 'action="[^"]+"' | head -1 \
        | sed 's/action="//;s/"$//' | sed 's/\&amp;/\&/g')
    [[ -z "$form_action" ]] && { rm -f "$cookies"; echo 000; return; }

    callback_url=$(curl -sk -b "$cookies" -c "$cookies" -o /dev/null -w "%{redirect_url}" \
        -X POST "$form_action" \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "password=${PASSWORD}" \
        --data-urlencode "credentialId=")
    [[ -z "$callback_url" ]] && { rm -f "$cookies"; echo 000; return; }

    code=$(curl -sk -b "$cookies" -c "$cookies" -L -o /dev/null -w "%{http_code}" "$callback_url")
    rm -f "$cookies"
    echo "$code"
}

# -----------------------------------------------------------------------------
# Test B — ${ITERATIONS} sequential full logins
# -----------------------------------------------------------------------------
echo -e "${BLUE}Test B — ${ITERATIONS} sequential full logins${NC}"
b_ok=0; b_ko=0
for i in $(seq 1 "$ITERATIONS"); do
    code=$(full_login)
    if [[ "$code" == "200" ]]; then
        b_ok=$((b_ok+1))
    else
        b_ko=$((b_ko+1))
        echo -e "    ${YELLOW}login #${i}: HTTP ${code}${NC}"
    fi
done
if [[ "$b_ko" -eq 0 ]]; then
    record pass "${b_ok}/${ITERATIONS} logins successful"
else
    record fail "${b_ko}/${ITERATIONS} logins failed"
fi
echo ""

# -----------------------------------------------------------------------------
# Test C — reproduce the actual race
# Fire N /oauth2/start requests into the SAME cookie jar before completing the
# flow. Without the fix, only the last CSRF cookie survives; completing any
# earlier flow returns 403. With the fix, every cookie coexists.
# -----------------------------------------------------------------------------
echo -e "${BLUE}Test C — race condition (parallel /oauth2/start + complete first flow)${NC}"
race_cookies=$(mktemp)
race_states=$(mktemp)

# Fire 5 parallel /oauth2/start against the same cookie jar and capture each
# Location's state-carrying URL.
for i in 1 2 3 4 5; do
    (curl -sk -c "${race_cookies}.${i}" -o /dev/null -w "%{redirect_url}\n" \
        "${STREAMLIT_URL}/oauth2/start?rd=/" >> "$race_states") &
done
wait

# Merge all cookie jars into one (simulating a browser accumulating cookies
# from multiple parallel requests).
: > "$race_cookies"
for i in 1 2 3 4 5; do cat "${race_cookies}.${i}" >> "$race_cookies" 2>/dev/null; rm -f "${race_cookies}.${i}"; done

# Pick the FIRST login URL and complete its flow. This is the case most likely
# to fail without the fix: its CSRF cookie was overwritten by the later ones.
first_login_url=$(head -1 "$race_states")
form_action=$(curl -sk -b "$race_cookies" -c "$race_cookies" "$first_login_url" \
    | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/\&amp;/\&/g')
callback_url=$(curl -sk -b "$race_cookies" -c "$race_cookies" -o /dev/null -w "%{redirect_url}" \
    -X POST "$form_action" \
    --data-urlencode "username=${USERNAME}" \
    --data-urlencode "password=${PASSWORD}" \
    --data-urlencode "credentialId=")
race_code=$(curl -sk -b "$race_cookies" -c "$race_cookies" -L -o /dev/null -w "%{http_code}" "$callback_url")
rm -f "$race_cookies" "$race_states"

if [[ "$race_code" == "200" ]]; then
    record pass "first flow completes cleanly after 5 parallel /oauth2/start (HTTP 200)"
else
    record fail "first flow returns HTTP ${race_code} — CSRF race is NOT fixed"
fi
echo ""

# -----------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$fail" -eq 0 ]]; then
    echo -e "${GREEN}🎉 ${pass}/${pass} tests passed${NC}"
    exit 0
else
    echo -e "${RED}❌ ${fail} test(s) failed, ${pass} passed${NC}"
    exit 1
fi
