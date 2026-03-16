---
name: auth-authz-patterns
description: Use when reviewing or implementing authentication and authorization — covers OAuth2 grant flows (Authorization Code + PKCE, Client Credentials, Device Flow), OpenID Connect (OIDC) and ID tokens, JWT best practices, RBAC and ABAC policy design, service-to-service authentication (mTLS, workload identity, API keys), session management security, and auth anti-patterns across TypeScript, Go, Java, and Python
---

# Authentication and Authorization Patterns

## Overview

Authentication (who you are) and authorization (what you can do) failures are among the most critical security vulnerabilities. Tokens stored in the wrong place, missing expiry, roles checked only on the frontend, hardcoded secrets — each is a breach waiting to happen. Use this guide during code review and implementation to catch auth hazards before they ship.

**When to use:** Reviewing auth flows, JWT handling, role/permission enforcement, service-to-service calls, session management, or any code dealing with identity and access control.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| OAuth2 Authorization Code + PKCE | Exchange short-lived code for tokens; PKCE prevents code interception | No PKCE on public clients, authorization code reuse |
| OAuth2 Client Credentials | Machine-to-machine token exchange using client secret | Client secret in source code or env var committed to VCS |
| OAuth2 Device Flow | Polling-based flow for input-constrained devices | No user code expiry, infinite polling |
| OIDC / ID Tokens | Identity layer on top of OAuth2; ID token asserts who the user is | Trusting ID token audience blindly, not validating `nonce` |
| JWT Best Practices | Short-lived access tokens, HttpOnly refresh cookies, rotation | JWT in localStorage, no expiry (`exp` claim missing) |
| RBAC | Roles mapped to permission sets; enforced server-side | Role checks only in UI, permission sprawl |
| ABAC / OPA / Cedar | Policy decisions based on subject + resource + environment attributes | Hardcoded attribute logic scattered in application code |
| mTLS / Workload Identity | Mutual TLS or platform identity (SPIFFE/SVID) for service auth | Shared API key across services, no certificate rotation |
| Session Management | Secure cookies, fixation prevention, rotation on privilege change | Session ID in URL, no rotation after login |
| Auth Anti-Patterns | Common mistakes that create vulnerabilities | localStorage JWT, no expiry, frontend-only role checks |

---

## Patterns in Detail

### 1. OAuth2 Authorization Code Flow with PKCE

**When to use:** Browser-based or mobile apps acting on behalf of a user.

**Red Flags:**
- No PKCE (`code_challenge` / `code_verifier`) on public clients — allows authorization code interception
- `state` parameter missing — open to CSRF on the redirect
- Authorization code reused or long-lived (>60 seconds)
- `redirect_uri` not validated strictly on the authorization server
- Access tokens passed in URL query params — appear in server logs

**TypeScript (PKCE generation):**
```typescript
import crypto from 'node:crypto';

function generatePKCE(): { verifier: string; challenge: string } {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto
    .createHash('sha256')
    .update(verifier)
    .digest('base64url');
  return { verifier, challenge };
}

// Build authorization URL
function buildAuthUrl(clientId: string, redirectUri: string): { url: string; verifier: string } {
  const { verifier, challenge } = generatePKCE();
  const state = crypto.randomBytes(16).toString('hex');
  // Store state + verifier in session (NOT localStorage)
  sessionStorage.setItem('oauth_state', state);
  sessionStorage.setItem('pkce_verifier', verifier);

  const params = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirectUri,
    scope: 'openid profile email',
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });
  return { url: `https://auth.example.com/authorize?${params}`, verifier };
}

// Token exchange at callback
async function exchangeCode(code: string, verifier: string, redirectUri: string): Promise<Tokens> {
  const resp = await fetch('https://auth.example.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: redirectUri,
      code_verifier: verifier,
      client_id: process.env.CLIENT_ID!,
    }),
  });
  if (!resp.ok) throw new Error(`Token exchange failed: ${resp.status}`);
  return resp.json() as Promise<Tokens>;
}
```

**Go (token validation after exchange):**
```go
import (
    "context"
    "github.com/coreos/go-oidc/v3/oidc"
    "golang.org/x/oauth2"
)

func ValidateToken(ctx context.Context, rawIDToken string) (*oidc.IDToken, error) {
    provider, err := oidc.NewProvider(ctx, "https://auth.example.com")
    if err != nil {
        return nil, fmt.Errorf("oidc provider: %w", err)
    }
    verifier := provider.Verifier(&oidc.Config{ClientID: os.Getenv("CLIENT_ID")})
    token, err := verifier.Verify(ctx, rawIDToken)
    if err != nil {
        return nil, fmt.Errorf("id token invalid: %w", err)
    }
    return token, nil
}
```

---

### 2. OAuth2 Client Credentials Flow

**When to use:** Server-to-server calls where no user is involved — background jobs, microservice APIs.

**Red Flags:**
- `client_secret` committed to source control or present in `.env` files checked in
- Token cached indefinitely — never refreshed when it expires
- Scope too broad — requesting `*` or admin-level scopes for a narrow use case
- Shared client credentials across multiple services — no blast-radius isolation

**Python:**
```python
import os
import time
import httpx
from dataclasses import dataclass, field

@dataclass
class TokenCache:
    access_token: str = ""
    expires_at: float = 0.0

_cache = TokenCache()

def get_service_token(scope: str = "reports:read") -> str:
    """Fetch and cache a client credentials token. Refresh 60s before expiry."""
    if _cache.access_token and time.time() < _cache.expires_at - 60:
        return _cache.access_token

    resp = httpx.post(
        "https://auth.example.com/token",
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["CLIENT_ID"],       # never hardcode
            "client_secret": os.environ["CLIENT_SECRET"],
            "scope": scope,
        },
        timeout=10,
    )
    resp.raise_for_status()
    payload = resp.json()
    _cache.access_token = payload["access_token"]
    _cache.expires_at = time.time() + payload["expires_in"]
    return _cache.access_token
```

**Java (Spring Security OAuth2 client):**
```java
@Bean
public OAuth2AuthorizedClientManager clientManager(
        ClientRegistrationRepository clientRepo,
        OAuth2AuthorizedClientRepository authorizedClientRepo) {
    var manager = new DefaultOAuth2AuthorizedClientManager(clientRepo, authorizedClientRepo);
    manager.setAuthorizedClientProvider(
        OAuth2AuthorizedClientProviderBuilder.builder().clientCredentials().build());
    return manager;
}

// Usage in service — Spring handles caching and refresh automatically
@Service
public class ReportClient {
    private final WebClient webClient;

    public ReportClient(WebClient.Builder builder, OAuth2AuthorizedClientManager manager) {
        var filter = new ServletOAuth2AuthorizedClientExchangeFilterFunction(manager);
        filter.setDefaultClientRegistrationId("report-service");
        this.webClient = builder.filter(filter).baseUrl("https://reports.internal").build();
    }

    public Mono<Report> fetchReport(String id) {
        return webClient.get().uri("/reports/{id}", id).retrieve().bodyToMono(Report.class);
    }
}
```

---

### 3. OpenID Connect (OIDC) and ID Tokens

**When to use:** Authenticating users via an identity provider; establishing who is logged in.

**Red Flags:**
- Using the ID token as an access token — ID tokens are for authentication, not API authorization
- Not validating `aud` (audience) claim — any relying party could accept your ID token
- Not validating `nonce` — replay attacks possible
- Not checking `iat` and `exp` — expired tokens accepted
- Trusting user-supplied `sub` without verifying issuer (`iss`)

**Token claims to always validate:**
```
iss  — matches expected issuer URL
aud  — contains your client_id
exp  — token is not expired
iat  — token was issued recently (clock skew ±30s)
nonce — matches value generated at auth request (prevents replay)
```

**TypeScript (ID token claim extraction after library validation):**
```typescript
import { jwtVerify, createRemoteJWKSet } from 'jose';

const JWKS = createRemoteJWKSet(new URL('https://auth.example.com/.well-known/jwks.json'));

interface IdTokenClaims {
  sub: string;
  email: string;
  name: string;
  nonce: string;
}

async function verifyIdToken(rawToken: string, expectedNonce: string): Promise<IdTokenClaims> {
  const { payload } = await jwtVerify(rawToken, JWKS, {
    issuer: 'https://auth.example.com',
    audience: process.env.CLIENT_ID,
  });
  if (payload.nonce !== expectedNonce) {
    throw new Error('nonce mismatch — possible replay attack');
  }
  return payload as unknown as IdTokenClaims;
}
```

---

### 4. JWT Best Practices

**When to use:** Any system issuing or consuming JSON Web Tokens.

**Red Flags:**
- JWT stored in `localStorage` — accessible to XSS; any injected script can steal it
- Missing or very long `exp` — compromised token valid indefinitely
- `alg: none` accepted — bypasses signature verification entirely
- RS256 key used for both signing and verification without isolating the private key
- Refresh tokens stored in `localStorage` — see above
- Token not invalidated on logout — must use a denylist or short-lived tokens

**Correct storage strategy:**
```
Access token  → memory (JS variable / React state) — short-lived (5–15 min)
Refresh token → HttpOnly, Secure, SameSite=Strict cookie — longer-lived (days)
```

**TypeScript (issuing tokens):**
```typescript
import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';

const ACCESS_TOKEN_TTL = 15 * 60;       // 15 minutes
const REFRESH_TOKEN_TTL = 7 * 24 * 3600; // 7 days

function issueTokenPair(userId: string, roles: string[]): { accessToken: string; refreshToken: string } {
  const accessToken = jwt.sign(
    { sub: userId, roles, jti: randomUUID() },
    process.env.JWT_SECRET!,
    { algorithm: 'HS256', expiresIn: ACCESS_TOKEN_TTL }
  );
  const refreshToken = jwt.sign(
    { sub: userId, jti: randomUUID() },
    process.env.REFRESH_SECRET!,
    { algorithm: 'HS256', expiresIn: REFRESH_TOKEN_TTL }
  );
  return { accessToken, refreshToken };
}

// Set refresh token as HttpOnly cookie — never expose to JS
function setRefreshCookie(res: Response, token: string): void {
  res.cookie('refresh_token', token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'strict',
    maxAge: REFRESH_TOKEN_TTL * 1000,
    path: '/auth/refresh',   // scope to refresh endpoint only
  });
}
```

**Token rotation (refresh endpoint):**
```typescript
app.post('/auth/refresh', async (req, res) => {
  const oldRefresh = req.cookies['refresh_token'];
  if (!oldRefresh) return res.status(401).json({ error: 'No refresh token' });

  try {
    const payload = jwt.verify(oldRefresh, process.env.REFRESH_SECRET!) as jwt.JwtPayload;
    // Check denylist (Redis) to prevent reuse of rotated tokens
    const revoked = await redis.get(`revoked:${payload.jti}`);
    if (revoked) return res.status(401).json({ error: 'Token reused' });

    // Revoke old token
    await redis.setex(`revoked:${payload.jti}`, REFRESH_TOKEN_TTL, '1');

    // Issue new pair
    const { accessToken, refreshToken } = issueTokenPair(payload.sub!, payload.roles ?? []);
    setRefreshCookie(res, refreshToken);
    res.json({ accessToken });
  } catch {
    res.status(401).json({ error: 'Invalid refresh token' });
  }
});
```

**Go (JWT validation middleware):**
```go
func JWTMiddleware(secret []byte) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            header := r.Header.Get("Authorization")
            if !strings.HasPrefix(header, "Bearer ") {
                http.Error(w, "missing token", http.StatusUnauthorized)
                return
            }
            tokenStr := strings.TrimPrefix(header, "Bearer ")
            token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
                if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
                    return nil, fmt.Errorf("unexpected alg: %v", t.Header["alg"])
                }
                return secret, nil
            })
            if err != nil || !token.Valid {
                http.Error(w, "invalid token", http.StatusUnauthorized)
                return
            }
            ctx := context.WithValue(r.Context(), claimsKey, token.Claims)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}
```

---

### 5. RBAC — Role-Based Access Control

**When to use:** Systems where access is determined by a user's assigned role (admin, editor, viewer, etc.).

**Red Flags:**
- Role checks only in the UI — API endpoints unprotected
- Roles stored in the JWT but never verified server-side from a trusted store
- God role (`admin`) used for unrelated functions — no principle of least privilege
- No audit log when role assignments change
- Permission logic duplicated across controllers instead of centralized

**TypeScript (middleware + decorator approach):**
```typescript
type Role = 'admin' | 'editor' | 'viewer';

function requireRole(...roles: Role[]) {
  return (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
    const userRoles: Role[] = req.user?.roles ?? [];
    const allowed = roles.some(r => userRoles.includes(r));
    if (!allowed) {
      return res.status(403).json({ error: 'Forbidden' });
    }
    next();
  };
}

// Routes declare required roles — enforcement is NOT in the UI
router.delete('/articles/:id', requireRole('admin', 'editor'), deleteArticle);
router.get('/admin/users', requireRole('admin'), listUsers);
```

**Java (Spring Security method security):**
```java
@Configuration
@EnableMethodSecurity
public class SecurityConfig { /* ... */ }

@Service
public class ArticleService {
    // RBAC enforced at service layer — not just controller
    @PreAuthorize("hasAnyRole('ADMIN', 'EDITOR')")
    public void deleteArticle(String id) { articleRepo.deleteById(id); }

    @PreAuthorize("hasRole('ADMIN')")
    public List<User> listUsers() { return userRepo.findAll(); }
}
```

**RBAC permission matrix design:**
```
Role      | create | read | update | delete | manage_users
----------|--------|------|--------|--------|-------------
viewer    |   -    |  X   |   -    |   -    |      -
editor    |   X    |  X   |   X    |   -    |      -
admin     |   X    |  X   |   X    |   X    |      X
```

---

### 6. ABAC — Attribute-Based Access Control with OPA / Cedar

**When to use:** Fine-grained policies where role alone is insufficient — decisions depend on resource attributes, environment, or context (e.g., "editors can only edit articles they own", "access allowed only between 09:00–17:00").

**Red Flags:**
- ABAC conditions embedded as `if/else` logic scattered across services
- Policies in application code instead of a dedicated policy engine — hard to audit and change
- No centralized policy store — policies drift across services over time
- Resource ownership not checked — any editor can mutate any resource

**OPA (Open Policy Agent) — Rego policy:**
```rego
package articles

import future.keywords.if

default allow := false

# Admins can do anything
allow if {
    input.user.role == "admin"
}

# Editors can update their own articles only
allow if {
    input.action == "update"
    input.user.role == "editor"
    input.resource.owner_id == input.user.id
}

# Viewers can only read published articles
allow if {
    input.action == "read"
    input.resource.status == "published"
}
```

**TypeScript (OPA sidecar query):**
```typescript
async function isAuthorized(input: PolicyInput): Promise<boolean> {
  const resp = await fetch('http://localhost:8181/v1/data/articles/allow', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ input }),
  });
  if (!resp.ok) throw new Error(`OPA error: ${resp.status}`);
  const { result } = await resp.json() as { result: boolean };
  return result;
}

// Middleware using OPA
function opaGuard(action: string) {
  return async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
    const allowed = await isAuthorized({
      user: { id: req.user.id, role: req.user.role },
      action,
      resource: req.resource,  // populated by prior middleware
    });
    if (!allowed) return res.status(403).json({ error: 'Forbidden' });
    next();
  };
}
```

**AWS Cedar policy (attribute-based):**
```cedar
permit(
    principal is User,
    action == Action::"update",
    resource is Article
)
when {
    principal.role == "editor" &&
    resource.ownerId == principal.id &&
    context.hour >= 9 && context.hour < 17
};
```

Cross-reference: `security-patterns-code-review` — policy enforcement checklist.

---

### 7. Service-to-Service Authentication

**When to use:** Microservices calling each other, background jobs hitting internal APIs.

**Red Flags:**
- Single shared API key for all services — one compromise exposes all communication
- API keys committed to source control or environment files checked into VCS
- No key rotation strategy — keys are permanent
- Self-signed certs accepted without pinning or CA validation
- No mutual authentication — only the client verifies the server

**mTLS with SPIFFE/SVID (Workload Identity):**
```go
// Both client and server present certificates — mutual verification
func newMTLSClient(certFile, keyFile, caFile string) (*http.Client, error) {
    cert, err := tls.LoadX509KeyPair(certFile, keyFile)
    if err != nil {
        return nil, fmt.Errorf("load cert: %w", err)
    }
    caCert, err := os.ReadFile(caFile)
    if err != nil {
        return nil, fmt.Errorf("read CA: %w", err)
    }
    caPool := x509.NewCertPool()
    if !caPool.AppendCertsFromPEM(caCert) {
        return nil, errors.New("invalid CA cert")
    }
    tlsCfg := &tls.Config{
        Certificates: []tls.Certificate{cert},
        RootCAs:      caPool,
        MinVersion:   tls.VersionTLS13,
    }
    return &http.Client{Transport: &http.Transport{TLSClientConfig: tlsCfg}}, nil
}
```

**Workload identity (Kubernetes / GCP):**
```python
import google.auth
import google.auth.transport.requests
import httpx

def call_internal_service(url: str) -> dict:
    """Use GCP workload identity — no static credentials."""
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    auth_req = google.auth.transport.requests.Request()
    credentials.refresh(auth_req)

    resp = httpx.get(url, headers={"Authorization": f"Bearer {credentials.token}"})
    resp.raise_for_status()
    return resp.json()
```

**API key best practices (when mTLS is not available):**
```typescript
// Key per service, rotated via secret manager — never in code
const INTERNAL_API_KEY = process.env.INTERNAL_API_KEY;
if (!INTERNAL_API_KEY) throw new Error('INTERNAL_API_KEY not configured');

function validateApiKey(req: Request, res: Response, next: NextFunction): void {
  const providedKey = req.headers['x-api-key'];
  // Constant-time comparison to prevent timing attacks
  const expected = Buffer.from(INTERNAL_API_KEY);
  const provided = Buffer.from(typeof providedKey === 'string' ? providedKey : '');
  if (provided.length !== expected.length || !crypto.timingSafeEqual(provided, expected)) {
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }
  next();
}
```

Cross-reference: `microservices-resilience-patterns` — service mesh for mTLS automation.

---

### 8. Session Management Security

**When to use:** Traditional server-side sessions (cookies) for web applications.

**Red Flags:**
- Session ID in the URL — logged in server logs, referrer headers, browser history
- No session rotation on privilege escalation (login, role change) — session fixation vulnerability
- Session cookie missing `HttpOnly`, `Secure`, or `SameSite` flags
- No absolute session timeout — session valid indefinitely if kept alive
- Predictable session IDs — sequential integers or MD5(username+time)

**TypeScript (Express session hardening):**
```typescript
import session from 'express-session';
import RedisStore from 'connect-redis';
import { createClient } from 'redis';

const redisClient = createClient({ url: process.env.REDIS_URL });
await redisClient.connect();

app.use(session({
  store: new RedisStore({ client: redisClient }),
  secret: process.env.SESSION_SECRET!,  // 32+ random bytes
  name: '__Host-sid',                   // __Host- prefix enforces secure + path=/
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    secure: true,
    sameSite: 'strict',
    maxAge: 30 * 60 * 1000,  // 30-minute idle timeout
  },
}));

// MANDATORY: rotate session on login to prevent fixation
app.post('/login', async (req, res) => {
  const user = await authenticate(req.body.email, req.body.password);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });

  // Regenerate session ID before setting user data
  req.session.regenerate((err) => {
    if (err) return res.status(500).json({ error: 'Session error' });
    req.session.userId = user.id;
    req.session.roles = user.roles;
    res.json({ ok: true });
  });
});

// Invalidate session on logout — do not just clear the cookie
app.post('/logout', (req, res) => {
  req.session.destroy((err) => {
    if (err) return res.status(500).json({ error: 'Logout failed' });
    res.clearCookie('__Host-sid');
    res.json({ ok: true });
  });
});
```

**Java (Spring Session + Redis):**
```java
@Configuration
@EnableRedisHttpSession(maxInactiveIntervalInSeconds = 1800)
public class SessionConfig {
    @Bean
    public CookieSerializer cookieSerializer() {
        DefaultCookieSerializer serializer = new DefaultCookieSerializer();
        serializer.setCookieName("__Host-sid");
        serializer.setUseHttpOnlyCookie(true);
        serializer.setUseSecureCookie(true);
        serializer.setSameSite("Strict");
        serializer.setCookiePath("/");
        return serializer;
    }
}
```

---

### 9. OAuth2 Device Flow

**When to use:** Input-constrained devices (smart TVs, CLI tools, IoT) where opening a browser is impractical.

**Red Flags:**
- No expiry on `user_code` — codes valid indefinitely create phishing surface
- Polling interval not respected — hammering the token endpoint
- Device code not invalidated after use — reuse possible
- User code too short or predictable — easy to brute-force

**TypeScript (device flow client):**
```typescript
interface DeviceCodeResponse {
  device_code: string;
  user_code: string;
  verification_uri: string;
  expires_in: number;
  interval: number;
}

async function authenticateDevice(): Promise<string> {
  // Step 1: Request device code
  const dcResp = await fetch('https://auth.example.com/device/code', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: process.env.CLIENT_ID!, scope: 'openid profile' }),
  });
  const dc: DeviceCodeResponse = await dcResp.json();

  console.log(`Go to ${dc.verification_uri} and enter: ${dc.user_code}`);

  // Step 2: Poll until authorized, expired, or denied
  const deadline = Date.now() + dc.expires_in * 1000;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, dc.interval * 1000));

    const tokenResp = await fetch('https://auth.example.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        device_code: dc.device_code,
        client_id: process.env.CLIENT_ID!,
      }),
    });
    const body = await tokenResp.json();

    if (tokenResp.ok) return body.access_token;
    if (body.error === 'slow_down') await new Promise(r => setTimeout(r, 5000));
    if (body.error === 'access_denied' || body.error === 'expired_token') {
      throw new Error(`Auth failed: ${body.error}`);
    }
    // authorization_pending — continue polling
  }
  throw new Error('Device code expired');
}
```

---

### 10. Auth Anti-Patterns

| Anti-Pattern | Why It's Dangerous | Fix |
|-------------|-------------------|-----|
| **JWT in localStorage** | XSS can read `localStorage`; any injected script steals the token | Store access token in memory; refresh token in `HttpOnly` cookie |
| **No token expiry** | Compromised token is valid forever | Always set `exp`; access tokens 5–15 min, refresh tokens days |
| **Frontend-only role checks** | UI checks are cosmetic — API is unprotected | Enforce roles/permissions in every API handler server-side |
| **Hardcoded secrets** | Secret committed to VCS is exposed to everyone with repo access | Use environment variables loaded from a secret manager |
| **Broad OAuth2 scopes** | Compromised token can access unrelated resources | Request only the minimum scopes needed |
| **No PKCE on public clients** | Authorization code can be intercepted and exchanged | Always use PKCE (`S256`) for browser and mobile apps |
| **Shared API keys across services** | One leak exposes all service communication | Issue a unique key per service; rotate via secret manager |
| **Session ID in URL** | Logged in server logs, referrer headers, and browser history | Use cookies only; never put session IDs in URLs |
| **alg:none JWT accepted** | Attacker creates unsigned tokens that pass verification | Explicitly whitelist allowed algorithms; reject `none` |
| **No logout invalidation** | Session/token valid after user logs out | Destroy server-side session; add JTI to a denylist on logout |

**Hardcoded secret — TypeScript fix:**
```typescript
// WRONG
const JWT_SECRET = 'my-super-secret-key-123';

// CORRECT — validated at startup
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET.length < 32) {
  throw new Error('JWT_SECRET must be set and at least 32 characters');
}
```

**Frontend-only role check — fix:**
```typescript
// WRONG — UI hides button but API is unprotected
{user.role === 'admin' && <DeleteButton />}

// CORRECT — API enforces the same rule
router.delete('/articles/:id',
  requireRole('admin'),   // middleware on the server
  deleteArticle
);
// UI check is cosmetic only — the real gate is the API
```

---

## Cross-References

- `security-patterns-code-review` — security review checklist: injection, secrets, authorization enforcement
- `state-management-patterns` — storing auth state in frontend; avoiding sensitive data in global stores
- `microservices-resilience-patterns` — service mesh mTLS, circuit breakers for auth service failures, retry on 401
