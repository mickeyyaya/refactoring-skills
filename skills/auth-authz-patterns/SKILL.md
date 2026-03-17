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

**TypeScript (PKCE generation + token exchange):**
```typescript
import crypto from 'node:crypto';

function generatePKCE() {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

function buildAuthUrl(clientId: string, redirectUri: string) {
  const { verifier, challenge } = generatePKCE();
  const state = crypto.randomBytes(16).toString('hex');
  sessionStorage.setItem('oauth_state', state);      // NOT localStorage
  sessionStorage.setItem('pkce_verifier', verifier);
  const params = new URLSearchParams({
    response_type: 'code', client_id: clientId, redirect_uri: redirectUri,
    scope: 'openid profile email', state,
    code_challenge: challenge, code_challenge_method: 'S256',
  });
  return { url: `https://auth.example.com/authorize?${params}`, verifier };
}

async function exchangeCode(code: string, verifier: string, redirectUri: string): Promise<Tokens> {
  const resp = await fetch('https://auth.example.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code, redirect_uri: redirectUri,
      code_verifier: verifier, client_id: process.env.CLIENT_ID!,
    }),
  });
  if (!resp.ok) throw new Error(`Token exchange failed: ${resp.status}`);
  return resp.json() as Promise<Tokens>;
}
```

**Go (OIDC token validation after exchange):**
```go
func ValidateToken(ctx context.Context, rawIDToken string) (*oidc.IDToken, error) {
    provider, err := oidc.NewProvider(ctx, "https://auth.example.com")
    if err != nil { return nil, fmt.Errorf("oidc provider: %w", err) }
    verifier := provider.Verifier(&oidc.Config{ClientID: os.Getenv("CLIENT_ID")})
    token, err := verifier.Verify(ctx, rawIDToken)
    if err != nil { return nil, fmt.Errorf("id token invalid: %w", err) }
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

**TypeScript (with caching + expiry):**
```typescript
let cachedToken = '';
let tokenExpiresAt = 0;

async function getServiceToken(scope = 'reports:read'): Promise<string> {
  if (cachedToken && Date.now() < tokenExpiresAt - 60_000) return cachedToken;
  const resp = await fetch('https://auth.example.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: process.env.CLIENT_ID!,      // never hardcode
      client_secret: process.env.CLIENT_SECRET!,
      scope,
    }),
  });
  if (!resp.ok) throw new Error(`Token fetch failed: ${resp.status}`);
  const { access_token, expires_in } = await resp.json();
  cachedToken = access_token;
  tokenExpiresAt = Date.now() + expires_in * 1000;
  return cachedToken;
}
```

Java (Spring Security OAuth2): wire `OAuth2AuthorizedClientManager` with `clientCredentials()` provider + `ServletOAuth2AuthorizedClientExchangeFilterFunction` on `WebClient` — Spring handles caching and refresh automatically. No manual token cache needed.

---

### 3. OpenID Connect (OIDC) and ID Tokens

**When to use:** Authenticating users via an identity provider; establishing who is logged in.

**Red Flags:**
- Using the ID token as an access token — ID tokens are for authentication, not API authorization
- Not validating `aud` (audience) claim — any relying party could accept your ID token
- Not validating `nonce` — replay attacks possible
- Not checking `iat` and `exp` — expired tokens accepted
- Trusting user-supplied `sub` without verifying issuer (`iss`)

**Claims to always validate:**
```
iss  — matches expected issuer URL
aud  — contains your client_id
exp  — token is not expired
iat  — token was issued recently (clock skew ±30s)
nonce — matches value generated at auth request (prevents replay)
```

**TypeScript (ID token validation with jose):**
```typescript
import { jwtVerify, createRemoteJWKSet } from 'jose';

const JWKS = createRemoteJWKSet(new URL('https://auth.example.com/.well-known/jwks.json'));

async function verifyIdToken(rawToken: string, expectedNonce: string): Promise<IdTokenClaims> {
  const { payload } = await jwtVerify(rawToken, JWKS, {
    issuer: 'https://auth.example.com',
    audience: process.env.CLIENT_ID,
  });
  if (payload.nonce !== expectedNonce) throw new Error('nonce mismatch — possible replay attack');
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
- Refresh tokens stored in `localStorage` — see above
- Token not invalidated on logout — must use a denylist or short-lived tokens

**Correct storage strategy:**
```
Access token  → memory (JS variable / React state) — short-lived (5–15 min)
Refresh token → HttpOnly, Secure, SameSite=Strict cookie — longer-lived (days)
```

**TypeScript (issuing tokens + refresh cookie):**
```typescript
import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';

const ACCESS_TOKEN_TTL = 15 * 60;        // 15 min
const REFRESH_TOKEN_TTL = 7 * 24 * 3600; // 7 days

function issueTokenPair(userId: string, roles: string[]) {
  const accessToken = jwt.sign({ sub: userId, roles, jti: randomUUID() },
    process.env.JWT_SECRET!, { algorithm: 'HS256', expiresIn: ACCESS_TOKEN_TTL });
  const refreshToken = jwt.sign({ sub: userId, jti: randomUUID() },
    process.env.REFRESH_SECRET!, { algorithm: 'HS256', expiresIn: REFRESH_TOKEN_TTL });
  return { accessToken, refreshToken };
}

function setRefreshCookie(res: Response, token: string): void {
  res.cookie('refresh_token', token, {
    httpOnly: true, secure: process.env.NODE_ENV === 'production',
    sameSite: 'strict', maxAge: REFRESH_TOKEN_TTL * 1000,
    path: '/auth/refresh',  // scope to refresh endpoint only
  });
}
```

**Token rotation (refresh endpoint — denylist via Redis JTI):**
```typescript
app.post('/auth/refresh', async (req, res) => {
  const oldRefresh = req.cookies['refresh_token'];
  if (!oldRefresh) return res.status(401).json({ error: 'No refresh token' });
  try {
    const payload = jwt.verify(oldRefresh, process.env.REFRESH_SECRET!) as jwt.JwtPayload;
    if (await redis.get(`revoked:${payload.jti}`)) return res.status(401).json({ error: 'Token reused' });
    await redis.setex(`revoked:${payload.jti}`, REFRESH_TOKEN_TTL, '1');  // revoke old
    const { accessToken, refreshToken } = issueTokenPair(payload.sub!, payload.roles ?? []);
    setRefreshCookie(res, refreshToken);
    res.json({ accessToken });
  } catch { res.status(401).json({ error: 'Invalid refresh token' }); }
});
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

**TypeScript (middleware approach):**
```typescript
type Role = 'admin' | 'editor' | 'viewer';

function requireRole(...roles: Role[]) {
  return (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
    const userRoles: Role[] = req.user?.roles ?? [];
    if (!roles.some(r => userRoles.includes(r))) return res.status(403).json({ error: 'Forbidden' });
    next();
  };
}
router.delete('/articles/:id', requireRole('admin', 'editor'), deleteArticle);
router.get('/admin/users', requireRole('admin'), listUsers);
```

**Java (Spring Security — annotation-based, enforced at service layer):**
```java
@Configuration @EnableMethodSecurity
public class SecurityConfig { /* ... */ }

@Service
public class ArticleService {
    @PreAuthorize("hasAnyRole('ADMIN', 'EDITOR')")
    public void deleteArticle(String id) { articleRepo.deleteById(id); }

    @PreAuthorize("hasRole('ADMIN')")
    public List<User> listUsers() { return userRepo.findAll(); }
}
```

Note: Spring annotations are materially different from Express middleware — they enforce at the service layer via AOP, not the HTTP layer.

**RBAC permission matrix:**
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

**OPA (Rego policy):**
```rego
package articles
import future.keywords.if
default allow := false

allow if { input.user.role == "admin" }

allow if {
    input.action == "update"
    input.user.role == "editor"
    input.resource.owner_id == input.user.id
}

allow if {
    input.action == "read"
    input.resource.status == "published"
}
```

**TypeScript (OPA sidecar query + middleware):**
```typescript
async function isAuthorized(input: PolicyInput): Promise<boolean> {
  const resp = await fetch('http://localhost:8181/v1/data/articles/allow', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ input }),
  });
  if (!resp.ok) throw new Error(`OPA error: ${resp.status}`);
  return (await resp.json() as { result: boolean }).result;
}

function opaGuard(action: string) {
  return async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
    const allowed = await isAuthorized({ user: { id: req.user.id, role: req.user.role }, action, resource: req.resource });
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

**mTLS with SPIFFE/SVID (Workload Identity) — Go:**
```go
func newMTLSClient(certFile, keyFile, caFile string) (*http.Client, error) {
    cert, err := tls.LoadX509KeyPair(certFile, keyFile)
    if err != nil { return nil, fmt.Errorf("load cert: %w", err) }
    caCert, _ := os.ReadFile(caFile)
    caPool := x509.NewCertPool()
    if !caPool.AppendCertsFromPEM(caCert) { return nil, errors.New("invalid CA cert") }
    return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
        Certificates: []tls.Certificate{cert}, RootCAs: caPool, MinVersion: tls.VersionTLS13,
    }}}, nil
}
```

**Workload identity (GCP/Kubernetes):** Use Application Default Credentials — platform injects a short-lived token via workload identity binding; no static credentials in code. For cross-cloud, use SPIFFE SVID via spiffe-helper sidecar.

**API key best practices (when mTLS is not available):**
```typescript
const INTERNAL_API_KEY = process.env.INTERNAL_API_KEY;
if (!INTERNAL_API_KEY) throw new Error('INTERNAL_API_KEY not configured');

function validateApiKey(req: Request, res: Response, next: NextFunction): void {
  const provided = req.headers['x-api-key'];
  const expected = Buffer.from(INTERNAL_API_KEY);
  const providedBuf = Buffer.from(typeof provided === 'string' ? provided : '');
  // Constant-time comparison to prevent timing attacks
  if (providedBuf.length !== expected.length || !crypto.timingSafeEqual(providedBuf, expected)) {
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
app.use(session({
  store: new RedisStore({ client: redisClient }),
  secret: process.env.SESSION_SECRET!,  // 32+ random bytes
  name: '__Host-sid',                   // __Host- prefix enforces secure + path=/
  resave: false, saveUninitialized: false,
  cookie: { httpOnly: true, secure: true, sameSite: 'strict', maxAge: 30 * 60 * 1000 },
}));

// MANDATORY: rotate session ID on login to prevent fixation
app.post('/login', async (req, res) => {
  const user = await authenticate(req.body.email, req.body.password);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });
  req.session.regenerate((err) => {
    if (err) return res.status(500).json({ error: 'Session error' });
    req.session.userId = user.id;
    req.session.roles = user.roles;
    res.json({ ok: true });
  });
});

// Destroy session on logout — do not just clear the cookie
app.post('/logout', (req, res) => {
  req.session.destroy((err) => {
    if (err) return res.status(500).json({ error: 'Logout failed' });
    res.clearCookie('__Host-sid');
    res.json({ ok: true });
  });
});
```

Java (Spring Session + Redis): equivalent via `@EnableRedisHttpSession(maxInactiveIntervalInSeconds = 1800)` + `DefaultCookieSerializer` with `setUseHttpOnlyCookie`, `setUseSecureCookie`, `setSameSite("Strict")`.

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
async function authenticateDevice(): Promise<string> {
  // Step 1: request device code
  const dc = await fetch('https://auth.example.com/device/code', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: process.env.CLIENT_ID!, scope: 'openid profile' }),
  }).then(r => r.json());
  console.log(`Go to ${dc.verification_uri} and enter: ${dc.user_code}`);

  // Step 2: poll until authorized or expired
  const deadline = Date.now() + dc.expires_in * 1000;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, dc.interval * 1000));
    const tokenResp = await fetch('https://auth.example.com/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        device_code: dc.device_code, client_id: process.env.CLIENT_ID!,
      }),
    });
    const body = await tokenResp.json();
    if (tokenResp.ok) return body.access_token;
    if (body.error === 'slow_down') await new Promise(r => setTimeout(r, 5000));
    if (body.error === 'access_denied' || body.error === 'expired_token')
      throw new Error(`Auth failed: ${body.error}`);
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

**Red Flags — quick fixes:**
```typescript
// WRONG: hardcoded secret
const JWT_SECRET = 'my-super-secret-key-123';
// CORRECT
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET.length < 32) throw new Error('JWT_SECRET must be set and ≥32 chars');

// WRONG: UI-only guard
{user.role === 'admin' && <DeleteButton />}
// CORRECT: server enforces the same rule
router.delete('/articles/:id', requireRole('admin'), deleteArticle);
```

---

## Cross-References

- `security-patterns-code-review` — security review checklist: injection, secrets, authorization enforcement
- `state-management-patterns` — storing auth state in frontend; avoiding sensitive data in global stores
- `microservices-resilience-patterns` — service mesh mTLS, circuit breakers for auth service failures, retry on 401
