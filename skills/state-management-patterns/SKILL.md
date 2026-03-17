---
name: state-management-patterns
description: Use when reviewing or designing client or server state — covers Flux/Redux unidirectional data flow, server state with React Query/SWR/TanStack Query, optimistic updates and rollback, finite state machines with XState, session management (cookie vs JWT, session fixation, secure flags), distributed session stores, derived state and selector memoization, and common state management anti-patterns with TypeScript/React examples and backend session examples
---

# State Management Patterns

## Overview

Mismanaged state is the root cause of most UI bugs, stale data issues, and security vulnerabilities in web applications. Uncoordinated mutations lead to race conditions, inconsistent UIs, and hard-to-reproduce bugs. Use this guide when designing new state architecture, reviewing pull requests that touch shared state, or diagnosing unexpected re-renders and data consistency issues.

**When to use:** Designing client or server state architecture; reviewing Redux/Zustand/Context code; evaluating server-state caching strategies; auditing session and authentication implementations; diagnosing UI inconsistency bugs.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Flux/Redux Unidirectional | Single store, actions → reducer → new state | Mutating state directly, actions with side effects in reducers |
| Server State (React Query/SWR) | Cache remote data separately from UI state | Manually managing loading/error booleans for every fetch |
| Optimistic Updates | Apply change immediately, rollback on failure | No rollback path, no error handling after mutation |
| Finite State Machines | Explicit states and transitions (XState) | Boolean flag explosion, impossible state combinations |
| Session Management | Secure cookie or JWT with proper flags | Missing HttpOnly/Secure flags, session fixation on login |
| Distributed Session Stores | Redis or DB-backed sessions for multi-instance apps | In-memory sessions break with multiple server instances |
| Derived State & Selectors | Compute from source of truth, memoize expensive derivations | Duplicating state that could be derived, missing memoization |
| Anti-Patterns | Global state abuse, prop drilling, state duplication | Everything in a global store, deeply nested prop chains |

---

## Patterns in Detail

### 1. Flux/Redux Unidirectional Data Flow

The core insight of Flux and Redux is that state flows in one direction: **action → reducer → store → view**. Views dispatch actions; they never mutate state directly.

**Red Flags:**
- Mutating state inside a reducer: `state.items.push(item)` instead of returning a new array
- Performing side effects (API calls, timers) inside reducers
- Dispatching actions from inside reducers (cascading dispatches)
- Accessing the store directly from deep components instead of using selectors
- Actions that carry computed/derived data that could be calculated in the reducer

**TypeScript — Redux Toolkit (immutable by convention via Immer):**
```typescript
import { createSlice, PayloadAction, configureStore } from '@reduxjs/toolkit';

interface CartItem { id: string; name: string; qty: number; price: number; }
interface CartState { items: CartItem[]; status: 'idle' | 'loading' | 'error'; }

const initialState: CartState = { items: [], status: 'idle' };

const cartSlice = createSlice({
  name: 'cart',
  initialState,
  reducers: {
    // RTK uses Immer — direct mutation is safe ONLY inside createSlice reducers
    addItem(state, action: PayloadAction<CartItem>) {
      const existing = state.items.find(i => i.id === action.payload.id);
      if (existing) {
        existing.qty += action.payload.qty;
      } else {
        state.items.push(action.payload);
      }
    },
    removeItem(state, action: PayloadAction<string>) {
      state.items = state.items.filter(i => i.id !== action.payload);
    },
    clearCart(state) {
      state.items = [];
    },
  },
});

export const { addItem, removeItem, clearCart } = cartSlice.actions;

// WRONG — never mutate store state outside a reducer
// store.getState().cart.items.push(newItem);

// CORRECT — dispatch an action
// store.dispatch(addItem({ id: 'abc', name: 'Widget', qty: 1, price: 9.99 }));
```

// Plain reducers without RTK follow the same pattern — pure function, spread to return new state, no mutation.

Cross-reference: `design-patterns-behavioral` — Command pattern for action objects; Observer for store subscriptions.

---

### 2. Server State Management (React Query / SWR / TanStack Query)

Server state is fundamentally different from UI state: it is remote, asynchronously fetched, can become stale, and is owned by the server. Libraries like React Query, SWR, and TanStack Query manage the full lifecycle (loading, caching, refetching, stale-while-revalidate) so application code does not have to.

**Red Flags:**
- Manual `useEffect` + `useState` for every data fetch — duplicated loading/error/data patterns
- No cache invalidation after mutations — stale data displayed after a successful write
- Fetching the same data independently in sibling components (N requests instead of 1)
- Blocking renders waiting for non-critical data when `suspense` or parallel queries could help
- No error boundaries around query consumers — uncaught errors unmount the full tree

**TypeScript — TanStack Query v5:**
```typescript
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';

interface User { id: string; name: string; email: string; }

// --- Data fetching ---
function useUser(id: string) {
  return useQuery<User, Error>({
    queryKey: ['users', id],
    queryFn: () => fetch(`/api/users/${id}`).then(r => {
      if (!r.ok) throw new Error(`Failed to fetch user ${id}: ${r.status}`);
      return r.json() as Promise<User>;
    }),
    staleTime: 5 * 60 * 1000,   // 5 min — don't refetch if data is fresh
    retry: (count, err) => count < 2 && !(err.message.includes('404')),
  });
}

// --- Mutation with cache invalidation ---
function useUpdateUser() {
  const queryClient = useQueryClient();
  return useMutation<User, Error, { id: string; name: string }>({
    mutationFn: ({ id, name }) =>
      fetch(`/api/users/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name }),
      }).then(r => r.json()),
    onSuccess: (_, { id }) => {
      queryClient.invalidateQueries({ queryKey: ['users', id] });
    },
  });
}

// Component usage — no manual loading state
function UserProfile({ userId }: { userId: string }) {
  const { data: user, isLoading, error } = useUser(userId);
  const updateUser = useUpdateUser();

  if (isLoading) return <Spinner />;
  if (error) return <ErrorMessage message={error.message} />;

  return (
    <div>
      <p>{user.name}</p>
      <button onClick={() => updateUser.mutate({ id: user.id, name: 'New Name' })}>
        Rename
      </button>
    </div>
  );
}
```

// SWR equivalent: `useSWR<User>(url, fetcher, { dedupingInterval: 2000 })` — after mutation call `mutate(url)` to trigger revalidation. Simpler API, same caching guarantees.

---

### 3. Optimistic Updates and Rollback

Optimistic updates apply changes to local state immediately without waiting for the server, then rollback if the request fails. This makes UIs feel instant but requires a careful rollback path.

**Red Flags:**
- Optimistic update with no rollback — UI shows success even when the server returns an error
- No loading indicator during the server round-trip — user double-clicks and duplicates the action
- Rollback silently discards the error instead of surfacing it to the user
- Optimistic update to a paginated list where the new item position is unknown

**TypeScript — TanStack Query optimistic update with rollback:**
```typescript
interface Todo { id: string; text: string; completed: boolean; }

function useToggleTodo() {
  const queryClient = useQueryClient();

  return useMutation<Todo, Error, string>({
    mutationFn: (id: string) =>
      fetch(`/api/todos/${id}/toggle`, { method: 'POST' }).then(r => r.json()),

    onMutate: async (id: string) => {
      await queryClient.cancelQueries({ queryKey: ['todos'] });
      const previousTodos = queryClient.getQueryData<Todo[]>(['todos']);

      queryClient.setQueryData<Todo[]>(['todos'], (old = []) =>
        old.map(t => t.id === id ? { ...t, completed: !t.completed } : t)
      );

      return { previousTodos };
    },

    onError: (_err, _id, context) => {
      if (context?.previousTodos) {
        queryClient.setQueryData(['todos'], context.previousTodos);
      }
    },

    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['todos'] });
    },
  });
}
```

// Zustand equivalent: snapshot `get().todos` before `set(...)`, catch the fetch error, call `set({ todos: snapshot })` to rollback, then rethrow to surface the error to the caller.

---

### 4. Finite State Machines (XState / Statecharts)

Finite state machines make every valid state and transition explicit, eliminating impossible states and the boolean flag explosion that leads to them.

**Red Flags:**
- Multiple booleans that must be kept in sync: `isLoading`, `isError`, `isSuccess`, `isRetrying` — combinations can be contradictory
- Missing transitions that allow going from `error` directly back to `loading` without resetting state
- No handling of concurrent requests — two fetches in flight, second result overwrites first
- Deeply nested `if/else` chains that represent implicit state logic

**Replace boolean flag explosion with an explicit union type:**
```typescript
// WRONG — 4 booleans = 16 combinations, most are impossible
// interface BadState { isIdle: boolean; isLoading: boolean; isSuccess: boolean; isError: boolean; }

// CORRECT — exactly 4 valid states, each with typed context
type FetchState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'success'; data: User }
  | { status: 'error'; error: Error };
```

**TypeScript — XState v5 actor:**
```typescript
import { createMachine, assign, createActor } from 'xstate';

const fetchUserMachine = createMachine({
  id: 'fetchUser',
  initial: 'idle',
  context: { userId: '' as string, user: null as User | null, error: null as Error | null },
  states: {
    idle: {
      on: { FETCH: { target: 'loading', actions: assign({ userId: ({ event }) => event.userId }) } },
    },
    loading: {
      invoke: {
        src: 'fetchUser',
        input: ({ context }) => ({ userId: context.userId }),
        onDone: { target: 'success', actions: assign({ user: ({ event }) => event.output }) },
        onError: { target: 'error', actions: assign({ error: ({ event }) => event.error as Error }) },
      },
    },
    success: {
      on: { RETRY: 'loading', RESET: 'idle' },
    },
    error: {
      on: { RETRY: 'loading', RESET: 'idle' },
    },
  },
}, {
  actors: {
    fetchUser: async ({ input }: { input: { userId: string } }) => {
      const r = await fetch(`/api/users/${input.userId}`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json() as Promise<User>;
    },
  },
});

// React: `useActorRef(fetchUserMachine)` + `useSelector(actorRef, s => s)` — send `{ type: 'FETCH', userId }` in a `useEffect` to start the machine.
```

Cross-reference: `design-patterns-behavioral` — State pattern for object-oriented finite state modeling.

---

### 5. Session Management (Cookie vs JWT, Session Fixation, Secure Flags)

Session management controls how authentication state is stored and transmitted. Mistakes here directly enable account takeover, session hijacking, and privilege escalation.

**Red Flags:**
- Cookies missing `HttpOnly` flag — JavaScript can read the session token (XSS attack vector)
- Cookies missing `Secure` flag — session transmitted over plain HTTP in mixed-content scenarios
- No `SameSite` attribute — exposes session to Cross-Site Request Forgery (CSRF)
- Session fixation: reusing the same session ID after login — attacker pre-sets a known session ID, user authenticates, attacker gains access
- Long-lived JWTs with no rotation — a stolen token is valid until expiry with no revocation path
- Storing sensitive data inside a JWT payload without encryption — base64 is not encryption

**Session fixation prevention — regenerate ID on login:**
```typescript
// Express + express-session
import session from 'express-session';
import { Request, Response, NextFunction } from 'express';

app.use(session({
  secret: process.env.SESSION_SECRET!,
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,   // blocks JavaScript access — mitigates XSS theft
    secure: true,     // HTTPS only
    sameSite: 'strict', // blocks CSRF
    maxAge: 30 * 60 * 1000, // 30 minutes
  },
}));

async function loginHandler(req: Request, res: Response) {
  const { username, password } = req.body;
  const user = await validateCredentials(username, password);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });

  // CRITICAL: regenerate session ID after login to prevent session fixation
  req.session.regenerate((err) => {
    if (err) return res.status(500).json({ error: 'Session error' });
    req.session.userId = user.id;
    req.session.role = user.role;
    res.json({ ok: true });
  });
}

async function logoutHandler(req: Request, res: Response) {
  req.session.destroy((err) => {
    res.clearCookie('connect.sid');
    res.json({ ok: true });
  });
}
```

**JWT — short-lived access token + refresh token rotation:**
```typescript
import jwt from 'jsonwebtoken';

const ACCESS_TTL = '15m';   // short-lived
const REFRESH_TTL = '7d';   // stored HttpOnly cookie, not localStorage

function issueTokens(userId: string, role: string) {
  const accessToken = jwt.sign(
    { sub: userId, role },
    process.env.JWT_ACCESS_SECRET!,
    { expiresIn: ACCESS_TTL, algorithm: 'HS256' }
  );
  const refreshToken = jwt.sign(
    { sub: userId },
    process.env.JWT_REFRESH_SECRET!,
    { expiresIn: REFRESH_TTL, algorithm: 'HS256' }
  );
  return { accessToken, refreshToken };
}

function setRefreshCookie(res: Response, token: string) {
  res.cookie('refresh_token', token, {
    httpOnly: true,
    secure: true,
    sameSite: 'strict',
    maxAge: 7 * 24 * 60 * 60 * 1000,
    path: '/auth/refresh', // scope cookie to refresh endpoint only
  });
}

// Never store JWT in localStorage — XSS can exfiltrate it
// Use memory for access token, HttpOnly cookie for refresh token
```

Cross-reference: `security-patterns-code-review` — Authentication flows, token validation, OWASP session management guidelines.

---

### 6. Distributed Session Stores (Redis, Database-Backed)

In-memory sessions break as soon as an application runs on more than one server instance. Load balancers route requests to different instances, each with its own in-memory session state. Distributed stores solve this.

**Red Flags:**
- `MemoryStore` in production — Node.js `express-session` warns about this explicitly; sessions lost on restart and cannot be shared across instances
- No session expiry set in the store — orphaned sessions accumulate indefinitely
- No connection pooling or error handling on the session store — store unavailability takes down the entire application
- Storing large objects in sessions — bloats store memory and increases serialization cost per request

**TypeScript — Redis session store with connection resilience:**
```typescript
import session from 'express-session';
import RedisStore from 'connect-redis';
import { createClient } from 'redis';

const redisClient = createClient({
  url: process.env.REDIS_URL,
  socket: { reconnectStrategy: (retries) => Math.min(retries * 50, 2000) },
});

redisClient.on('error', (err) => logger.error('Redis session store error', { err }));
await redisClient.connect();

app.use(session({
  store: new RedisStore({
    client: redisClient,
    prefix: 'sess:',
    ttl: 1800,          // 30 minutes in seconds — matches cookie maxAge
  }),
  secret: process.env.SESSION_SECRET!,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, secure: true, sameSite: 'strict', maxAge: 1800000 },
}));
```

// Database-backed alternative: `connect-pg-simple` or `connect-mongo` — same `session({ store: new PgStore({ conString, tableName, pruneSessionInterval }) })` pattern. Set `pruneSessionInterval` to auto-expire orphaned sessions.

**Session data contract — store only the minimum:**
```typescript
declare module 'express-session' {
  interface SessionData {
    userId: string;
    role: 'admin' | 'user' | 'guest';
    // WRONG — never store full user objects, tokens, or sensitive PII
    // user: User;
    // accessToken: string;
  }
}
```

Cross-reference: `concurrency-patterns` — distributed locking to prevent race conditions on session writes.

---

### 7. Derived State and Selector Memoization

Derived state is computed from existing state rather than stored separately. Storing derivable values creates duplication that drifts out of sync. Memoized selectors prevent recomputing expensive derivations on every render.

**Red Flags:**
- Storing a `totalPrice` field alongside `items` — must be kept in sync with every mutation
- Running expensive filter/sort/aggregate logic inside a component render without memoization
- `useSelector` returning a new object reference on every call — causes unnecessary re-renders even when underlying data has not changed
- Calling `Array.filter().map().reduce()` chains on large arrays inside component bodies

**TypeScript — Reselect memoized selectors:**
```typescript
import { createSelector } from 'reselect';
import { RootState } from './store';

const selectCartItems = (state: RootState) => state.cart.items;
const selectTaxRate = (state: RootState) => state.settings.taxRate;

// Only recomputes when items or taxRate changes
export const selectCartSummary = createSelector(
  [selectCartItems, selectTaxRate],
  (items, taxRate) => {
    const subtotal = items.reduce((sum, item) => sum + item.price * item.qty, 0);
    const tax = subtotal * taxRate;
    return { subtotal, tax, total: subtotal + tax, itemCount: items.reduce((s, i) => s + i.qty, 0) };
  }
);
// Component: `const { subtotal, tax, total, itemCount } = useSelector(selectCartSummary);` — only re-renders when summary values actually change.
```

**React useMemo for local derived state:**
```typescript
function ProductList({ products, searchTerm, category }: Props) {
  // Only recomputes when products, searchTerm, or category changes
  const filtered = useMemo(
    () => products
      .filter(p => p.category === category && p.name.toLowerCase().includes(searchTerm.toLowerCase()))
      .sort((a, b) => a.name.localeCompare(b.name)),
    [products, searchTerm, category]
  );

  return <ul>{filtered.map(p => <ProductItem key={p.id} product={p} />)}</ul>;
}
```

Cross-reference: `concurrency-patterns` — memoization strategies and cache invalidation in concurrent contexts.

---

### 8. State Management Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Global State Abuse** | Putting ephemeral UI state (tooltip open, input focus) in a global store | Use local `useState` for component-scoped state; only promote to global when truly shared |
| **Prop Drilling** | Passing props through 4+ component layers when only the leaf needs them | Use React Context for cross-cutting concerns or a state library for shared domain state |
| **State Duplication** | Storing the same data in two places (store + local state) that drift apart | Single source of truth; derive or select everywhere else |
| **Derived State in Store** | Storing `totalPrice` alongside `items` when it can be calculated | Remove derived fields; compute via selectors |
| **Overusing Context** | Using React Context for frequently-updated state — causes all consumers to re-render | Reserve Context for slow-changing config (theme, locale); use Zustand/Redux for dynamic state |
| **Missing Rehydration** | SSR renders a different initial state than client, causing hydration mismatch | Pass server-fetched state as initial data to the client store |
| **No State Reset on Logout** | Cached user data persists after logout — visible to the next user on a shared device | Dispatch a `RESET` action or call `queryClient.clear()` on logout |
| **Action Spam** | Dispatching multiple actions that each trigger a re-render, when one batched action would suffice | Batch related mutations into a single action |

**Global state abuse — use local state for component-scoped concerns:**
```typescript
// WRONG — tooltip visibility does not need to be in Redux
// dispatch(setTooltipVisible({ id: 'help', visible: true }));

// CORRECT — local state for local concerns
function HelpButton() {
  const [tooltipOpen, setTooltipOpen] = useState(false);
  return (
    <button onMouseEnter={() => setTooltipOpen(true)} onMouseLeave={() => setTooltipOpen(false)}>
      Help {tooltipOpen && <Tooltip text="Click for docs" />}
    </button>
  );
}
```

**Prop drilling — replace with context; consumers read directly:**
```typescript
const ThemeContext = createContext<Theme>({ mode: 'light' });

function App() {
  const [theme] = useState<Theme>({ mode: 'light' });
  return (
    <ThemeContext.Provider value={theme}>
      <Layout />  {/* no theme prop needed on intermediaries */}
    </ThemeContext.Provider>
  );
}

function NavItem() {
  const theme = useContext(ThemeContext);
  return <a className={theme.mode === 'dark' ? 'nav-dark' : 'nav-light'}>Home</a>;
}
```

**State reset on logout:**
```typescript
// Redux — reducer handles RESET at root level
function rootReducer(state: RootState | undefined, action: Action): RootState {
  if (action.type === 'auth/logout') {
    return rootReducer(undefined, action);  // reset all slices to initialState
  }
  return combinedReducers(state, action);
}

// TanStack Query — clear all cached server state on logout
async function logout() {
  await fetch('/api/auth/logout', { method: 'POST' });
  queryClient.clear();
  navigate('/login');
}
```

---

## State Architecture Decision Guide

| Use Case | Recommended Approach |
|----------|---------------------|
| Component-local UI state (modal open, form input) | `useState` / `useReducer` |
| Shared UI state across sibling components | Lift state up or Zustand store slice |
| Cross-cutting config (theme, locale, feature flags) | React Context |
| Remote/server data with caching and invalidation | TanStack Query / SWR |
| Complex async workflows with multiple states | XState finite state machine |
| High-frequency updates (real-time, animations) | Local state or `useRef` (avoid global store) |
| Authentication state | Session cookie (server-rendered) or memory + HttpOnly refresh cookie (SPA) |
| Multi-instance backend sessions | Redis or database-backed session store |

---

## Cross-References

- `design-patterns-behavioral` — Command pattern for action objects; Observer for store subscriptions; State pattern for FSM modeling
- `concurrency-patterns` — Async/Await pitfalls for async action creators; distributed locking for session writes; memoization and cache invalidation
- `security-patterns-code-review` — Authentication flows, JWT validation, OWASP session management, CSRF/XSS mitigations
