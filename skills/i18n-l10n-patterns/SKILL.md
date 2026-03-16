---
name: i18n-l10n-patterns
description: Use when building or reviewing internationalized applications — covers message externalization, ICU MessageFormat, CLDR plural rules, Intl.DateTimeFormat/NumberFormat, RTL layout with CSS logical properties, Intl.Collator for locale-correct sorting, translation workflow, pseudo-localization testing, and i18n anti-patterns across TypeScript and React
---

# Internationalization and Localization Patterns

## Overview

Hardcoded strings, binary plural logic, and locale-less date formatting create invisible bugs that only surface when users switch languages or regions. Use this guide when building new features that display user-visible text, numbers, dates, or currency — and during code review to catch i18n defects before they ship.

**When to use:** Any feature that renders text, numbers, dates, times, or currency to users; reviewing components for hardcoded strings; evaluating plural and date formatting logic; adding RTL language support; designing translation workflows.

## Quick Reference

| Topic | Core Idea | Primary Red Flag |
|-------|-----------|-----------------|
| Message Externalization | All user-visible strings in resource bundles or JSON | String literals in JSX/templates |
| ICU MessageFormat | Rich interpolation, plurals, selects in one syntax | String concatenation to build sentences |
| CLDR Plural Rules | Six categories: zero/one/two/few/many/other | `count === 1 ? "item" : "items"` binary check |
| Intl.DateTimeFormat | Locale-aware date/time via native API | `toLocaleDateString()` without explicit locale |
| Intl.NumberFormat | Locale-aware numbers and currency | Manual decimal/comma formatting |
| RTL Layout | CSS logical properties + `dir` attribute | `margin-left`, `padding-right` hard-coding direction |
| Intl.Collator | Locale-correct string sorting | `Array.sort()` with default JS comparator |
| Translation Workflow | Key-based lookups, context annotations, interpolation | Source strings directly in JSX |
| i18n Testing | Pseudo-localization, string expansion, missing key detection | No i18n-specific test coverage |

---

## Patterns in Detail

### 1. Message Externalization

Store every user-visible string outside source code in resource bundles (`.properties`, `.po`) or structured JSON translation files. Business logic must never contain literal display strings.

**Red Flags:**
- String literals inside JSX: `<h1>Welcome back!</h1>`
- Template literals building UI text: `` `Hello ${name}, you have ${n} messages` ``
- Error messages hardcoded in API responses
- Strings mixed with logic: `label = isAdmin ? "Admin Panel" : "My Dashboard"`

**TypeScript/React — JSON translation file (`en.json`):**
```json
{
  "nav.dashboard": "My Dashboard",
  "nav.admin": "Admin Panel",
  "welcome.greeting": "Welcome back, {name}!",
  "cart.items": "{count, plural, one {# item} other {# items}} in your cart"
}
```

**React component using `react-intl`:**
```tsx
import { FormattedMessage, useIntl } from 'react-intl';

// BEFORE — hardcoded string, not translatable
function Header({ name }: { name: string }) {
  return <h1>Welcome back, {name}!</h1>;
}

// AFTER — externalized to translation file
function Header({ name }: { name: string }) {
  return (
    <h1>
      <FormattedMessage id="welcome.greeting" values={{ name }} />
    </h1>
  );
}

// Programmatic access via hook
function PageTitle({ isAdmin }: { isAdmin: boolean }) {
  const intl = useIntl();
  const title = intl.formatMessage({ id: isAdmin ? 'nav.admin' : 'nav.dashboard' });
  return <title>{title}</title>;
}
```

**Resource bundle pattern (Node.js / `i18next`):**
```typescript
import i18next from 'i18next';

await i18next.init({
  lng: 'en',
  fallbackLng: 'en',
  resources: {
    en: { translation: require('./locales/en.json') },
    de: { translation: require('./locales/de.json') },
    ar: { translation: require('./locales/ar.json') },
  },
});

// Use in service layer — never hardcode the string here
const message = i18next.t('welcome.greeting', { name: user.displayName });
```

Cross-reference: `code-documentation-patterns` — annotating translation keys with context comments for translators.

---

### 2. ICU MessageFormat and Interpolation

ICU MessageFormat is the standard syntax for rich message patterns: variable interpolation, plural selection, gender select, and date/number formatting all within a single message string. This eliminates string concatenation that breaks translation.

**Red Flags:**
- Concatenated sentence fragments: `"You have " + count + " new messages"`
- Separate translation keys for singular/plural: `msg.singular` / `msg.plural`
- Gender/select logic in component code instead of message string
- Positional placeholders (`{0}`, `%s`) that cannot be reordered by translators

**ICU MessageFormat syntax reference:**
```
Simple variable:   "Hello, {name}!"
Plural:            "{count, plural, =0 {No items} one {# item} other {# items}}"
Select:            "{gender, select, male {He} female {She} other {They}} replied."
Date:              "Joined {date, date, medium}"
Number:            "Balance: {amount, number, ::currency/USD}"
Nested:            "{count, plural, one {{name} sent a message} other {{name} sent # messages}}"
```

**TypeScript with `@formatjs/intl`:**
```typescript
import { createIntl, createIntlCache } from '@formatjs/intl';

const cache = createIntlCache();
const intl = createIntl({ locale: 'en-US', messages: enMessages }, cache);

// Handles plurals, interpolation, and locale in one call
const text = intl.formatMessage(
  { id: 'cart.items' },
  { count: cartItems.length }
);
// en-US: "3 items in your cart"
// de-DE: "3 Artikel in Ihrem Warenkorb"
```

**React `FormattedMessage` with select for gender:**
```tsx
<FormattedMessage
  id="reply.notification"
  values={{ gender: user.gender, name: user.displayName }}
/>
// Translation: "{gender, select, male {He} female {She} other {They}} replied to your post."
```

---

### 3. CLDR Plural Rules

The Unicode CLDR defines six plural categories — `zero`, `one`, `two`, `few`, `many`, `other` — that vary by language. English only uses `one` and `other`, but Arabic uses all six. Binary `count === 1` checks are always wrong for non-English locales.

**Red Flags:**
- `count === 1 ? 'item' : 'items'` — binary plural, fails for Arabic, Slavic, and other languages
- Only two translation keys when six CLDR plural categories exist
- Missing `zero` form for languages where zero has distinct grammar (Arabic, Welsh)
- Client-side plural logic in JavaScript instead of ICU MessageFormat

**Binary plural anti-pattern:**
```typescript
// WRONG — only works for English; breaks Arabic, Polish, Russian
function getItemLabel(count: number): string {
  return count === 1 ? 'item' : 'items';
}
```

**Correct approach — ICU plural in translation string:**
```json
{
  "en": {
    "search.results": "{count, plural, =0 {No results} one {# result} other {# results}}"
  },
  "ar": {
    "search.results": "{count, plural, zero {لا نتائج} one {نتيجة واحدة} two {نتيجتان} few {# نتائج} many {# نتيجة} other {# نتيجة}}"
  },
  "pl": {
    "search.results": "{count, plural, one {# wynik} few {# wyniki} many {# wyników} other {# wyników}}"
  }
}
```

**React with CLDR-compliant formatting:**
```tsx
// The intl library handles CLDR plural selection based on locale
function SearchResultCount({ count }: { count: number }) {
  return (
    <span>
      <FormattedMessage id="search.results" values={{ count }} />
    </span>
  );
}
```

Cross-reference: `data-validation-schema-patterns` — validating locale codes against CLDR language tag schemas.

---

### 4. Date and Time Formatting

Always use `Intl.DateTimeFormat` with an explicit locale and timezone. Never rely on `Date.toString()`, `toLocaleDateString()` without locale, or manual format strings — these produce inconsistent output across environments.

**Red Flags:**
- `date.toLocaleDateString()` without locale — uses system locale, not user preference
- `date.toISOString().split('T')[0]` for display — always renders as `YYYY-MM-DD` regardless of locale
- Hardcoded format string: `${month}/${day}/${year}` — month/day order varies by locale
- Missing timezone: `new Intl.DateTimeFormat('en-US')` — uses local timezone, not user's timezone

**TypeScript date formatting utilities:**
```typescript
// BEFORE — locale and timezone ignored
function formatDate(date: Date): string {
  return date.toLocaleDateString(); // uses runtime system locale
}

// AFTER — explicit locale and timezone
function formatDate(date: Date, locale: string, timeZone: string): string {
  return new Intl.DateTimeFormat(locale, {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone,
  }).format(date);
}

function formatDateTime(date: Date, locale: string, timeZone: string): string {
  return new Intl.DateTimeFormat(locale, {
    dateStyle: 'medium',
    timeStyle: 'short',
    timeZone,
  }).format(date);
}

// Usage
formatDate(new Date('2024-03-15'), 'en-US', 'America/New_York');  // "March 15, 2024"
formatDate(new Date('2024-03-15'), 'de-DE', 'Europe/Berlin');     // "15. März 2024"
formatDate(new Date('2024-03-15'), 'ja-JP', 'Asia/Tokyo');        // "2024年3月15日"
```

**React — store timezone in user context:**
```tsx
interface UserLocaleContext {
  locale: string;
  timeZone: string;
}

function EventTime({ date, ctx }: { date: Date; ctx: UserLocaleContext }) {
  const formatted = new Intl.DateTimeFormat(ctx.locale, {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: ctx.timeZone,
  }).format(date);
  // Provide machine-readable datetime for screen readers and SEO
  return <time dateTime={date.toISOString()}>{formatted}</time>;
}
```

**Relative time with `Intl.RelativeTimeFormat`:**
```typescript
function formatRelativeTime(diffMs: number, locale: string): string {
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  const diffSeconds = Math.round(diffMs / 1000);
  if (Math.abs(diffSeconds) < 60) return rtf.format(diffSeconds, 'second');
  const diffMinutes = Math.round(diffSeconds / 60);
  if (Math.abs(diffMinutes) < 60) return rtf.format(diffMinutes, 'minute');
  return rtf.format(Math.round(diffMinutes / 60), 'hour');
}
// "yesterday", "in 2 hours", "3 minutes ago" — locale-correct
```

---

### 5. Number and Currency Formatting

Use `Intl.NumberFormat` for all numeric display. Decimal separators, thousands grouping characters, and currency symbol placement differ by locale — never format numbers manually.

**Red Flags:**
- Manual comma insertion: `num.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')`
- Hardcoded currency symbol: `$${price.toFixed(2)}`
- `toLocaleString()` without explicit locale — environment-dependent output
- Mixing currency codes and symbols: using `$` when user may be in a multi-currency region

**TypeScript number formatting:**
```typescript
// BEFORE — US-only formatting, breaks for European locales
function formatPrice(amount: number): string {
  return `$${amount.toFixed(2)}`; // "1234.56" in de-DE should be "1.234,56"
}

// AFTER — locale-aware currency formatting
function formatCurrency(
  amount: number,
  currency: string,
  locale: string
): string {
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    minimumFractionDigits: 2,
  }).format(amount);
}

formatCurrency(1234.56, 'USD', 'en-US');  // "$1,234.56"
formatCurrency(1234.56, 'EUR', 'de-DE');  // "1.234,56 €"
formatCurrency(1234.56, 'JPY', 'ja-JP');  // "¥1,235"

// Compact notation
new Intl.NumberFormat('en-US', { notation: 'compact' }).format(1_500_000);  // "1.5M"
new Intl.NumberFormat('ja-JP', { notation: 'compact' }).format(1_500_000);  // "150万"

// Percentage
new Intl.NumberFormat('en-US', { style: 'percent' }).format(0.762);  // "76%"
new Intl.NumberFormat('ar-EG', { style: 'percent' }).format(0.762);  // "٧٦٪"
```

**React currency component:**
```tsx
function Price({ amount, currency }: { amount: number; currency: string }) {
  const { locale } = useLocale(); // from context
  const formatted = new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
  }).format(amount);
  return <span className="price">{formatted}</span>;
}
```

---

### 6. RTL Layout Support

Right-to-left languages (Arabic, Hebrew, Persian, Urdu) require mirrored layouts. Use CSS logical properties (`margin-inline-start`, `padding-inline-end`) instead of physical properties (`margin-left`, `padding-right`), and set the `dir` attribute on the root element.

**Red Flags:**
- `margin-left`, `padding-right`, `border-left` in component CSS — these do not flip for RTL
- No `dir` attribute on `<html>` or component roots
- Icons or chevrons not mirrored for RTL (back arrow becomes forward arrow)
- `text-align: left` hardcoded instead of `text-align: start`
- Absolutely positioned elements using `left`/`right` instead of `inset-inline-start`/`inset-inline-end`

**CSS logical properties:**
```css
/* BEFORE — physical properties, break in RTL */
.card {
  padding-left: 16px;
  padding-right: 16px;
  border-left: 4px solid var(--accent);
  margin-left: auto;
  text-align: left;
}

/* AFTER — logical properties, correct in both LTR and RTL */
.card {
  padding-inline-start: 16px;
  padding-inline-end: 16px;
  border-inline-start: 4px solid var(--accent);
  margin-inline-start: auto;
  text-align: start;
}
```

**React — setting `dir` attribute from locale:**
```tsx
const RTL_LOCALES = new Set(['ar', 'he', 'fa', 'ur']);

function getTextDirection(locale: string): 'ltr' | 'rtl' {
  const lang = locale.split('-')[0];
  return RTL_LOCALES.has(lang) ? 'rtl' : 'ltr';
}

function App({ locale }: { locale: string }) {
  const dir = getTextDirection(locale);
  return (
    <html lang={locale} dir={dir}>
      <body>{/* content */}</body>
    </html>
  );
}
```

**Mirroring icons conditionally:**
```tsx
function BackButton() {
  const { dir } = useTextDirection();
  return (
    <button>
      <ChevronIcon
        style={{ transform: dir === 'rtl' ? 'scaleX(-1)' : 'none' }}
        aria-hidden="true"
      />
      <FormattedMessage id="nav.back" />
    </button>
  );
}
```

**Tailwind CSS logical property utilities (v3.3+):**
```html
<!-- BEFORE — physical, breaks RTL -->
<div class="ml-4 pr-6 text-left border-l-2">...</div>

<!-- AFTER — logical, works for both directions -->
<div class="ms-4 pe-6 text-start border-s-2">...</div>
```

---

### 7. String Collation and Locale-Correct Sorting

JavaScript's default `Array.sort()` uses Unicode code point order, which is incorrect for most locales. Use `Intl.Collator` for locale-aware sorting — especially for names, product lists, and search results.

**Red Flags:**
- `items.sort()` or `items.sort((a, b) => a.localeCompare(b))` without explicit locale
- `localeCompare()` without collator options — ignores sensitivity and numeric sorting
- Sorting names server-side with `ORDER BY name` without locale-aware collation
- Treating sort order as stable across locales (Swedish `å` sorts after `z`, not after `a`)

**TypeScript collation utilities:**
```typescript
// BEFORE — code point order, wrong for most languages
const sorted = names.sort();

// AFTER — locale-correct collation
function sortByName(items: string[], locale: string): string[] {
  const collator = new Intl.Collator(locale, {
    sensitivity: 'base',  // ignore case and diacritics for equality
    ignorePunctuation: true,
  });
  return [...items].sort((a, b) => collator.compare(a, b)); // immutable sort
}

sortByName(['Ångström', 'Äpfel', 'Apple', 'azure'], 'sv-SE');
// Swedish: ['Äpfel', 'Apple', 'azure', 'Ångström'] — Ä comes after Z in Swedish

sortByName(['Ångström', 'Äpfel', 'Apple', 'azure'], 'de-DE');
// German: ['Äpfel', 'Ångström', 'Apple', 'azure'] — Ä treated as Ae

// Numeric sort: "item2" before "item10"
const numericCollator = new Intl.Collator('en-US', { numeric: true });
['item10', 'item2', 'item1'].sort((a, b) => numericCollator.compare(a, b));
// ['item1', 'item2', 'item10']
```

**React table with locale-correct sorting:**
```tsx
function SortableNameList({
  users,
  locale,
}: {
  users: User[];
  locale: string;
}) {
  const collator = useMemo(
    () => new Intl.Collator(locale, { sensitivity: 'base' }),
    [locale]
  );

  const sorted = useMemo(
    () => [...users].sort((a, b) => collator.compare(a.name, b.name)),
    [users, collator]
  );

  return (
    <ul>
      {sorted.map((user) => (
        <li key={user.id}>{user.name}</li>
      ))}
    </ul>
  );
}
```

---

### 8. Translation Workflow

Keys should be semantic identifiers (not source strings). Provide context comments for translators. Keep interpolation variables descriptive. Never expose raw ICU syntax to translators without tooling support.

**Red Flags:**
- Keys that are the source string: `t('Hello, world!')` — breaks when English text changes
- No context for ambiguous keys: `t('open')` — is this a verb or an adjective?
- Positional placeholders `{0}`, `{1}` — translator cannot tell what they represent
- Massive flat translation files without namespace organization
- Concatenation in keys: `t('status.' + status)` — static analysis cannot find usages

**Key naming conventions:**
```json
{
  "_comment": "Context for translator: Button label shown in checkout flow, submits payment",
  "checkout.payment.submit_button": "Pay {formattedAmount}",

  "_comment": "Context: Status badge on order list, adjective describing order state",
  "order.status.open": "Open",
  "order.status.closed": "Closed",
  "order.status.pending": "Pending",

  "_comment": "Context: Error shown when payment card is declined",
  "checkout.error.card_declined": "Your card was declined. Please try a different payment method."
}
```

**TypeScript — type-safe translation keys:**
```typescript
// Generate types from translation file to catch missing keys at compile time
import en from './locales/en.json';

type TranslationKey = keyof typeof en;

function t(key: TranslationKey, values?: Record<string, string | number>): string {
  return intl.formatMessage({ id: key }, values);
}

// TypeScript error if key doesn't exist in en.json
t('checkout.payment.submit_button', { formattedAmount: '$42.00' }); // OK
t('checkout.nonexistent_key'); // TypeScript compile error
```

**Namespace organization for large apps:**
```typescript
// i18next namespace pattern
const namespaces = {
  common: 'common',     // shared UI: buttons, labels, errors
  checkout: 'checkout', // checkout flow
  profile: 'profile',   // user profile
  admin: 'admin',       // admin panel (only loaded for admins)
};

// Lazy-load namespaces on demand
await i18next.loadNamespaces('checkout');
i18next.t('checkout:payment.submit_button');
```

Cross-reference: `code-documentation-patterns` — JSDoc `@i18n` annotations on functions that return user-visible strings.

---

### 9. i18n Testing

i18n bugs are invisible in development when only English is tested. Pseudo-localization, string expansion simulation, and missing key detection catch issues before reaching production.

**Red Flags:**
- No pseudo-locale in development or CI
- Only testing with English locale
- No assertion that all keys in source locale exist in target locales
- Layout tests not run with longest translations (German is ~35% longer than English)
- No detection for untranslated strings (keys rendered raw)

**Pseudo-localization utility:**
```typescript
// Transforms English text to visually distinct but readable pseudo-locale
// Catches hardcoded strings that bypass the translation system
function pseudoLocalize(text: string): string {
  const charMap: Record<string, string> = {
    a: 'â', e: 'ê', i: 'î', o: 'ô', u: 'û',
    A: 'Â', E: 'Ê', I: 'Î', O: 'Ô', U: 'Û',
  };
  // Add brackets to show string boundaries, expand for string expansion testing
  const transformed = text
    .split('')
    .map((c) => charMap[c] ?? c)
    .join('');
  return `[!! ${transformed} !!]`; // brackets reveal untranslated strings
}

// "Hello, world!" → "[!! Hêllô, wôrld! !!]"
```

**String expansion simulation (German ~35% longer):**
```typescript
function simulateStringExpansion(text: string, factor = 1.4): string {
  const padding = 'x'.repeat(Math.ceil(text.length * (factor - 1)));
  return `${text}${padding}`;
}

// Use in layout tests to verify UI doesn't overflow or truncate
```

**Missing key detection in tests:**
```typescript
import en from '../locales/en.json';
import de from '../locales/de.json';
import ar from '../locales/ar.json';

describe('translation completeness', () => {
  const enKeys = new Set(Object.keys(en));

  test.each([
    ['de', de],
    ['ar', ar],
  ])('%s has all required keys', (locale, translations) => {
    const localeKeys = new Set(Object.keys(translations));
    const missingKeys = [...enKeys].filter((k) => !localeKeys.has(k));
    expect(missingKeys).toEqual([]);
  });
});
```

**React component i18n test:**
```tsx
import { render, screen } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import de from '../locales/de.json';
import { ProductCard } from './ProductCard';

test('renders product price in German locale', () => {
  render(
    <IntlProvider locale="de-DE" messages={de}>
      <ProductCard price={29.99} currency="EUR" />
    </IntlProvider>
  );
  // German locale formats as "29,99 €"
  expect(screen.getByText('29,99 €')).toBeInTheDocument();
});

test('renders plural correctly for Arabic locale', () => {
  // Test that CLDR plural rules are applied, not binary English logic
  render(
    <IntlProvider locale="ar" messages={ar}>
      <ResultCount count={3} />
    </IntlProvider>
  );
  expect(screen.getByRole('status')).toHaveTextContent('٣ نتائج');
});
```

Cross-reference: `testing-patterns` — snapshot testing caveats when locale output is included in snapshots.

---

## i18n Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Binary Plurals** | `count === 1 ? "item" : "items"` — only works in English | Use ICU `{count, plural, one {# item} other {# items}}` with CLDR categories |
| **Hardcoded Strings** | String literals in JSX or templates | Externalize to JSON translation files; use `FormattedMessage` or `t()` |
| **Concatenated Sentences** | `"You have " + count + " new " + type + " messages"` | Single ICU message with all variables: `"You have {count} new {type} messages"` |
| **Locale-less Intl** | `new Intl.DateTimeFormat().format(date)` — uses system locale | Always pass explicit locale: `new Intl.DateTimeFormat(userLocale, options)` |
| **Physical CSS** | `margin-left`, `padding-right`, `text-align: left` | CSS logical properties: `margin-inline-start`, `padding-inline-end`, `text-align: start` |
| **Source String Keys** | `t('Click here to submit')` — key breaks when English changes | Semantic keys: `t('form.submit_button')` |
| **No Translator Context** | `t('open')` — ambiguous for translators | Add context comments: is it a verb, adjective, or noun? |
| **Imperative Date Format** | `${month}/${day}/${year}` | `Intl.DateTimeFormat` with `dateStyle` option |
| **Default JS Sort** | `names.sort()` or sort without locale | `new Intl.Collator(locale).compare` |
| **Missing Fallback Locale** | App crashes when translation key not found | Configure `fallbackLng` in i18next; log missing keys in development |

**Concatenated sentence anti-pattern:**
```typescript
// WRONG — translator cannot reorder "username" and "channel" in their language
const msg = t('posted_in') + ' ' + username + ' ' + t('in_channel') + ' ' + channel;

// CORRECT — translator receives the full pattern and controls word order
const msg = t('activity.posted_in_channel', { username, channel });
// Translation: "{username} posted in {channel}" (EN)
// Translation: "{channel} で {username} が投稿しました" (JA — different word order)
```

---

## Cross-References

- `testing-patterns` — snapshot test pitfalls with locale-sensitive output; integration test setup for multiple locales
- `code-documentation-patterns` — annotating translation keys with `@i18n` context comments; documenting locale assumptions in function signatures
- `data-validation-schema-patterns` — validating BCP 47 language tags, IANA timezone identifiers, and ISO 4217 currency codes at API boundaries
- `review-code-quality-process` — i18n checklist: check for hardcoded strings, binary plurals, and locale-less Intl usage during code review
- `detect-code-smells` — "Magic Strings": hardcoded display text is a code smell indicating missing externalization
