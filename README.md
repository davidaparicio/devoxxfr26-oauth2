# Streamlit + Keycloak + OAuth2-Proxy Demo

Local Kubernetes demo of Streamlit authentication via Keycloak and OAuth2-Proxy.

## Quick Start

```bash
./install.sh    # Create KIND cluster, install all components
./secure.sh     # Enable OAuth2-Proxy authentication
```

**Access:**
- Streamlit: https://streamlit.127.0.0.1.nip.io:30443
- Keycloak Admin: https://keycloak.127.0.0.1.nip.io:30443 (admin/admin)

**Demo Users:**
- `demo` / `demo` - Regular user
- `demo2` / `demo2` - Member of `beta-users` group

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Install everything: KIND, cert-manager, nginx, Keycloak, oauth2-proxy, Streamlit |
| `secure.sh` | Enable OAuth2-Proxy authentication for Streamlit |
| `group.sh` | Restrict access to `beta-users` group only |
| `kyverno.sh` | Demo Kyverno policy enforcement (auto-adds auth annotations) |

## Cleanup

```bash
kind delete cluster --name streamlit
```

## Architecture

- **Keycloak**: Identity provider (OIDC)
- **OAuth2-Proxy**: Authentication proxy
- **Streamlit**: Demo application
- **nginx-ingress**: TLS termination
- **cert-manager**: Self-signed certificates
