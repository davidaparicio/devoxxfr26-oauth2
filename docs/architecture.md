# Architecture OAuth2-Proxy + Streamlit + Keycloak

## Vue d'ensemble

Ce document décrit l'architecture de protection d'une application Streamlit avec OAuth2-Proxy et Keycloak comme fournisseur d'identité.

## Schéma d'architecture

```mermaid
flowchart TB
    subgraph Client
        U[👤 Utilisateur<br/>Navigateur]
    end

    subgraph "Kubernetes Cluster"
        subgraph "Ingress Layer"
            ING[🌐 Ingress Controller]
        end

        subgraph "Authentication Layer"
            OP[🔐 OAuth2-Proxy<br/>Port 4180]
        end

        subgraph "Application Layer"
            ST[📊 Streamlit App<br/>Port 8501]
        end

        subgraph "Identity Provider"
            KC[🔑 Keycloak<br/>Port 8080]
        end
    end

    U -->|1. Requête initiale| ING
    ING -->|2. Redirection| OP
    OP -->|3. Non authentifié ?<br/>Redirection login| KC
    KC -->|4. Page de connexion| U
    U -->|5. Credentials| KC
    KC -->|6. Authorization Code| OP
    OP -->|7. Échange code → tokens| KC
    KC -->|8. Access Token + ID Token| OP
    OP -->|9. Cookie de session| U
    U -->|10. Requête avec cookie| ING
    ING --> OP
    OP -->|11. Validation token| KC
    OP -->|12. Proxy requête<br/>+ Headers utilisateur| ST
    ST -->|13. Réponse| OP
    OP -->|14. Réponse| U

    style U fill:#e1f5fe
    style OP fill:#fff3e0
    style ST fill:#e8f5e9
    style KC fill:#fce4ec
    style ING fill:#f3e5f5
```

## Flux d'authentification

| Étape | Description |
|-------|-------------|
| 1-2 | L'utilisateur accède à l'application via l'Ingress |
| 3-4 | OAuth2-Proxy détecte l'absence de session et redirige vers Keycloak |
| 5-6 | L'utilisateur s'authentifie, Keycloak renvoie un code d'autorisation |
| 7-8 | OAuth2-Proxy échange le code contre des tokens (OIDC flow) |
| 9 | Un cookie de session sécurisé est créé côté client |
| 10-12 | Les requêtes suivantes passent par OAuth2-Proxy qui injecte les headers utilisateur |
| 13-14 | Streamlit répond, la réponse est relayée à l'utilisateur |

## Diagramme de séquence

```mermaid
sequenceDiagram
    autonumber
    participant U as 👤 Utilisateur
    participant ING as 🌐 Ingress
    participant OP as 🔐 OAuth2-Proxy
    participant ST as 📊 Streamlit
    participant KC as 🔑 Keycloak

    U->>ING: GET /app
    ING->>OP: Forward request
    OP->>OP: Vérification cookie de session

    alt Pas de session valide
        OP->>U: 302 Redirect → /oauth2/start
        U->>OP: GET /oauth2/start
        OP->>U: 302 Redirect → Keycloak /auth
        U->>KC: GET /auth (authorize endpoint)
        KC->>U: Page de login
        U->>KC: POST credentials
        KC->>KC: Validation credentials
        KC->>U: 302 Redirect → /oauth2/callback?code=xxx
        U->>OP: GET /oauth2/callback?code=xxx
        OP->>KC: POST /token (code + client_secret)
        KC->>OP: Access Token + ID Token + Refresh Token
        OP->>OP: Création session + cookie
        OP->>U: 302 Redirect → /app + Set-Cookie
    end

    U->>ING: GET /app + Cookie
    ING->>OP: Forward request
    OP->>OP: Validation session/token
    OP->>ST: Forward + Headers (X-Forwarded-User, etc.)
    ST->>OP: Response (HTML/JSON)
    OP->>U: Response
```

## Headers injectés par OAuth2-Proxy

OAuth2-Proxy injecte automatiquement les headers suivants vers l'application protégée :

| Header | Description |
|--------|-------------|
| `X-Forwarded-User` | Nom d'utilisateur authentifié |
| `X-Forwarded-Email` | Email de l'utilisateur |
| `X-Forwarded-Groups` | Groupes/rôles de l'utilisateur |
| `X-Forwarded-Access-Token` | Token d'accès JWT (si configuré) |
| `X-Forwarded-Preferred-Username` | Username préféré |

## Composants

### OAuth2-Proxy

- **Rôle** : Reverse proxy d'authentification
- **Port** : 4180
- **Fonction** : Intercepte toutes les requêtes et vérifie l'authentification

### Streamlit

- **Rôle** : Application web Python
- **Port** : 8501
- **Fonction** : Application métier protégée

### Keycloak

- **Rôle** : Identity Provider (IdP) OpenID Connect
- **Port** : 8080
- **Fonction** : Gestion des utilisateurs, authentification, émission de tokens

### Ingress Controller

- **Rôle** : Point d'entrée du cluster
- **Fonction** : Routage TLS, load balancing
