---
name: data-validation-schema-patterns
description: Use when reviewing code for data validation correctness — covers validation boundary principle, TypeScript (Zod, Joi, io-ts), Python (Pydantic v2, marshmallow, dataclasses), Go (go-playground/validator), Java (Bean Validation / Hibernate Validator), schema evolution and compatibility, coercion vs strict parsing, custom validators, composable schemas, and validation anti-patterns with red flags and fix strategies
---

# Data Validation and Schema Patterns for Code Review

## Overview

Unvalidated input is the root cause of injection attacks, data corruption, and unexpected crashes. Validation is not a one-time gate at the UI layer — every system boundary must enforce its own schema contract. Use this guide during code review to catch validation hazards before they ship.

**When to use:** Reviewing code that accepts external data (HTTP requests, queue messages, file uploads, CLI args, environment variables); designing API contracts; evaluating schema evolution for backward compatibility; auditing trust boundaries in internal services.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Validation Boundary | Validate at every trust boundary, not just at the UI | Passing raw `unknown` / `any` deep into business logic |
| TypeScript / Zod | Runtime schema tied to compile-time type | `z.any()` escapes, skipping `.parse()` on external data |
| TypeScript / Joi | Rich rule DSL with detailed error messages | `.unknown(true)` without explicit allow-list |
| TypeScript / io-ts | Codec = decoder + encoder, composable | Ignoring `left` branch of `Either` decode result |
| Python / Pydantic v2 | Model-first validation, high performance | `model_config = {'arbitrary_types_allowed': True}` masking issues |
| Python / marshmallow | Schema-centric, explicit serialization control | `load()` result used without checking validation errors |
| Python / dataclasses | Structural typing only, no runtime enforcement | Trusting `@dataclass` fields have the declared type at runtime |
| Go / validator | Struct tag-based declarative rules | Missing `binding:"required"` tags on mandatory fields |
| Java / Bean Validation | Annotation-driven, integrates with frameworks | `@Valid` missing on nested objects or method parameters |
| Schema Evolution | Additive changes are safe; removals and renames break | Removing required fields without a deprecation cycle |
| Strict vs Coercive | Coercion silently accepts wrong types; strict fails fast | `z.coerce.number()` accepting `"abc"` → `NaN` |
| Custom Validators | Encode business rules as first-class schema constraints | Business rule checks scattered outside schema definition |

---

## Patterns in Detail

### 1. Validation Boundary Principle

**Core Rule:** Every system boundary — HTTP endpoint, queue consumer, file parser, CLI argument, environment variable, IPC call, or internal service API — is a trust boundary. Data that crosses a trust boundary must be validated before it is used.

**Red Flags:**
- `unknown` or `any` typed parameters passed directly to repository or service functions
- Validation only at the presentation layer; business logic assumes clean data
- Internal microservice calls skipping validation because "we control both sides"
- A single validation at ingestion time, then raw structs passed across multiple layers

**The Trust Boundary Map:**
```
External World
  → HTTP Request body        ← VALIDATE HERE
  → Query/path parameters    ← VALIDATE HERE
  → Message queue payload    ← VALIDATE HERE
  → File upload content      ← VALIDATE HERE
  → Env variables at startup ← VALIDATE HERE
  Internal Services
    → Inter-service HTTP      ← VALIDATE HERE (defense-in-depth)
    → DB query results        ← VALIDATE HERE (schema drift)
```

**TypeScript — boundary enforcement with Zod:**
```typescript
// WRONG — accepts unknown and passes it through
async function createUser(body: unknown) {
  return userRepo.insert(body as User); // any shape can reach the DB
}

// CORRECT — validate at the HTTP boundary, then work with typed data
const CreateUserSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(100),
  role: z.enum(['admin', 'viewer']),
});

async function createUser(body: unknown): Promise<User> {
  const input = CreateUserSchema.parse(body); // throws ZodError on failure
  return userRepo.insert(input);              // input is typed CreateUser
}
```

---

### 2. TypeScript Validation — Zod, Joi, io-ts

#### Zod

**Red Flags:**
- `z.any()` or `z.unknown()` used as a shortcut instead of a proper schema
- `.safeParse()` result used without checking `.success`
- Schemas defined per-request instead of at module level (performance)
- Missing `.strict()` — extra fields pass through silently

**Pattern — schema as the single source of truth:**
```typescript
import { z } from 'zod';

// Define once; derive the TypeScript type from it
const OrderSchema = z.object({
  id: z.string().uuid(),
  items: z.array(
    z.object({
      sku: z.string().min(1),
      qty: z.number().int().positive(),
      priceUsd: z.number().nonnegative(),
    })
  ).min(1),
  shippingAddress: z.object({
    street: z.string(),
    city: z.string(),
    postalCode: z.string().regex(/^\d{5}$/),
  }),
}).strict(); // reject unknown keys

export type Order = z.infer<typeof OrderSchema>; // no duplication

// Safe parse — return Result instead of throwing
function parseOrder(raw: unknown): { ok: true; order: Order } | { ok: false; errors: string[] } {
  const result = OrderSchema.safeParse(raw);
  if (!result.success) {
    return { ok: false, errors: result.error.errors.map(e => `${e.path.join('.')}: ${e.message}`) };
  }
  return { ok: true, order: result.data };
}
```

#### Joi

**Red Flags:**
- `.unknown(true)` on root schema — any extra key is silently passed
- `abortEarly: true` (default) — stops at first error; clients see one error at a time
- No `.label()` on fields — error messages reference internal key names

```typescript
import Joi from 'joi';

const schema = Joi.object({
  email: Joi.string().email().required().label('Email'),
  age: Joi.number().integer().min(18).max(120).required().label('Age'),
}).options({ allowUnknown: false, abortEarly: false }); // collect all errors

const { error, value } = schema.validate(input);
if (error) {
  const messages = error.details.map(d => d.message);
  throw new ValidationError(messages);
}
```

#### io-ts

**Red Flags:**
- Ignoring the `Left` branch (validation failure) of `Either`
- Using `t.any` or `t.unknown` in codec definitions
- Decoding without the `PathReporter` for human-readable errors

```typescript
import * as t from 'io-ts';
import { PathReporter } from 'io-ts/PathReporter';
import { isLeft } from 'fp-ts/Either';

const UserCodec = t.type({
  id: t.string,
  email: t.string,
  role: t.union([t.literal('admin'), t.literal('viewer')]),
});
export type User = t.TypeOf<typeof UserCodec>;

function decodeUser(raw: unknown): User {
  const result = UserCodec.decode(raw);
  if (isLeft(result)) {
    throw new ValidationError(PathReporter.report(result).join('; '));
  }
  return result.right;
}
```

---

### 3. Python Validation — Pydantic v2, marshmallow, dataclasses

#### Pydantic v2

**Red Flags:**
- `model_config = ConfigDict(arbitrary_types_allowed=True)` used to suppress type errors
- `model.model_dump()` then re-instantiating a model — unnecessary round-trip
- Missing `@field_validator` for cross-field constraints
- `model_validate(data)` called with trusted-but-unverified internal dicts

```python
from pydantic import BaseModel, EmailStr, field_validator, model_validator
from typing import Literal

class OrderItem(BaseModel):
    sku: str
    qty: int
    price_usd: float

    @field_validator('qty')
    @classmethod
    def qty_must_be_positive(cls, v: int) -> int:
        if v <= 0:
            raise ValueError('qty must be positive')
        return v

class Order(BaseModel):
    model_config = {'extra': 'forbid'}  # reject unknown keys

    id: str
    items: list[OrderItem]
    status: Literal['pending', 'shipped', 'delivered']

    @model_validator(mode='after')
    def at_least_one_item(self) -> 'Order':
        if not self.items:
            raise ValueError('order must have at least one item')
        return self

# Validate at boundary — raises ValidationError with detailed messages
order = Order.model_validate(raw_payload)
```

#### marshmallow

**Red Flags:**
- `schema.load()` result stored without checking for `ValidationError`
- `many=True` load without error handling per-item
- `dump_default` masking missing required fields on output

```python
from marshmallow import Schema, fields, validate, ValidationError, post_load

class UserSchema(Schema):
    email = fields.Email(required=True)
    name = fields.Str(required=True, validate=validate.Length(min=1, max=100))
    age = fields.Int(required=True, validate=validate.Range(min=18))

    @post_load
    def make_user(self, data, **kwargs):
        return User(**data)  # transform to domain object

schema = UserSchema()
try:
    user = schema.load(request_data)
except ValidationError as e:
    raise BadRequestError(e.messages)
```

#### dataclasses — limitation note

`@dataclass` provides structural convenience but NO runtime type enforcement. Use only for internal data transfer objects where the source is already validated.

```python
from dataclasses import dataclass

# WRONG — treating dataclass as a validator
@dataclass
class Config:
    port: int
    host: str

cfg = Config(**raw_env_dict)  # port could be "abc" — no error raised

# CORRECT — validate with Pydantic first, then convert or use Pydantic directly
class ConfigModel(BaseModel):
    port: int
    host: str

cfg = ConfigModel.model_validate(raw_env_dict)
```

---

### 4. Go Validation — go-playground/validator and Custom

**Red Flags:**
- Struct tags present but `validate.Struct(s)` never called
- `binding:"required"` used in Gin/Echo but missing on nested struct fields
- Validation errors cast to string directly — field path information lost
- Custom validators registered globally but not tested in isolation

```go
package validation

import (
    "fmt"
    "github.com/go-playground/validator/v10"
)

var validate = validator.New()

type CreateOrderRequest struct {
    UserID string      `json:"userId" validate:"required,uuid4"`
    Items  []OrderItem `json:"items"  validate:"required,min=1,dive"`
    Email  string      `json:"email"  validate:"required,email"`
}

type OrderItem struct {
    SKU string `json:"sku" validate:"required,min=1"`
    Qty int    `json:"qty" validate:"required,gt=0"`
}

func ValidateCreateOrder(req CreateOrderRequest) error {
    if err := validate.Struct(req); err != nil {
        var errs validator.ValidationErrors
        if ok := errors.As(err, &errs); ok {
            msgs := make([]string, len(errs))
            for i, e := range errs {
                msgs[i] = fmt.Sprintf("%s: failed %s", e.Field(), e.Tag())
            }
            return fmt.Errorf("validation failed: %s", strings.Join(msgs, "; "))
        }
        return err
    }
    return nil
}

// Custom validator registered at startup
func init() {
    _ = validate.RegisterValidation("sku_format", func(fl validator.FieldLevel) bool {
        return skuRegexp.MatchString(fl.Field().String())
    })
}
```

---

### 5. Java Validation — Bean Validation and Hibernate Validator

**Red Flags:**
- `@Valid` missing on nested object parameters — nested fields not validated
- `@NotNull` used on primitive types — redundant; `@NotBlank` needed for strings
- Controller method parameter missing `@Valid` — Spring skips validation silently
- Custom `ConstraintValidator` not registered in `ValidationConfig`
- `javax.validation` (old) mixed with `jakarta.validation` (new) in the same project

```java
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import jakarta.validation.ConstraintValidator;
import jakarta.validation.ConstraintValidatorContext;

// Domain model with Bean Validation annotations
public class CreateOrderRequest {

    @NotBlank(message = "userId is required")
    private String userId;

    @Valid                           // propagates validation into nested objects
    @NotEmpty(message = "items required")
    @Size(min = 1, message = "at least one item required")
    private List<OrderItem> items;

    @Email(message = "invalid email format")
    @NotBlank
    private String email;

    // getters / setters
}

public class OrderItem {
    @NotBlank
    private String sku;

    @Positive(message = "qty must be positive")
    private int qty;
}

// Spring controller — @Valid triggers Bean Validation
@RestController
public class OrderController {

    @PostMapping("/orders")
    public ResponseEntity<OrderResponse> createOrder(@Valid @RequestBody CreateOrderRequest req,
                                                     BindingResult result) {
        if (result.hasErrors()) {
            List<String> errors = result.getFieldErrors().stream()
                .map(e -> e.getField() + ": " + e.getDefaultMessage())
                .collect(Collectors.toList());
            throw new ValidationException(errors);
        }
        return ResponseEntity.ok(orderService.create(req));
    }
}

// Custom constraint — Hibernate Validator extension
@Target({ElementType.FIELD})
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = SkuFormatValidator.class)
public @interface ValidSku {
    String message() default "invalid SKU format";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}

public class SkuFormatValidator implements ConstraintValidator<ValidSku, String> {
    private static final Pattern SKU_PATTERN = Pattern.compile("^[A-Z]{3}-\\d{4}$");

    @Override
    public boolean isValid(String value, ConstraintValidatorContext ctx) {
        return value != null && SKU_PATTERN.matcher(value).matches();
    }
}
```

---

### 6. Schema Evolution and Compatibility

Schema evolution governs how validation schemas change over time without breaking existing clients.

**Additive-safe changes** (backward compatible — old clients still pass validation):
- Adding optional fields with defaults
- Widening accepted value ranges
- Adding new enum values (if consumers use unknown-value fallbacks)

**Breaking changes** (require deprecation cycle or API versioning):
- Removing a field
- Renaming a field
- Narrowing accepted value range (e.g., `max=1000` → `max=500`)
- Adding a new required field
- Changing a field's type

**Red Flags:**
- Required field added to an existing schema without bumping API version
- Enum values removed without checking all consumers
- Field renamed in schema but consumers still send the old key
- No schema version field — impossible to migrate gracefully

**Pattern — additive evolution with default:**
```typescript
// v1 schema
const UserV1 = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
});

// v2 schema — additive: role is optional with a default
const UserV2 = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
  role: z.enum(['admin', 'viewer']).default('viewer'), // safe — old clients omit field
});

// v2 schema — BREAKING: makes name required
const UserV2Breaking = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
  name: z.string(), // old clients don't send this — BREAKING CHANGE
});
```

**Python / Pydantic — forward-compatible model:**
```python
from pydantic import BaseModel
from typing import Optional

class UserV2(BaseModel):
    model_config = {'extra': 'ignore'}  # tolerate unknown fields from newer producers

    id: str
    email: str
    role: str = 'viewer'          # safe default for old producers
    display_name: Optional[str] = None  # new optional field
```

---

### 7. Coercion vs Strict Parsing

**Coercion** automatically converts values to the target type (`"42"` → `42`). It is convenient but can mask data quality issues and silently accept malformed inputs.

**Strict parsing** rejects any value that is not already the correct type. Prefer strict mode at system boundaries.

**Red Flags:**
- `z.coerce.number()` accepting `""` → `0` or `"abc"` → `NaN`
- Pydantic coercing `"false"` → `False` on a boolean field when the source is an HTTP header that should be `0`/`1`
- Coercion hiding producer bugs: producer sends a string, consumer silently converts — the bug is never fixed

```typescript
// WRONG — coercion masks producer bugs
const Schema = z.object({
  count: z.coerce.number(), // "abc" → NaN, "" → 0; both silently accepted
});

// CORRECT — strict; reject non-numbers at the boundary
const StrictSchema = z.object({
  count: z.number().int().nonnegative(),
});

// ACCEPTABLE — coercion only for known string-to-number scenarios (e.g., query params)
const QuerySchema = z.object({
  page: z.coerce.number().int().positive().default(1),
}).strict();
```

```python
# Pydantic strict mode per field
from pydantic import BaseModel, StrictInt, StrictStr

class StrictOrder(BaseModel):
    id: StrictStr    # rejects int 42, only accepts str "42"
    qty: StrictInt   # rejects "5", only accepts int 5
```

---

### 8. Custom Validators and Composable Schemas

Encode domain invariants as reusable schema components instead of ad-hoc `if` checks in business logic.

**Red Flags:**
- Business rule checks duplicated across multiple endpoints (DRY violation)
- Validation logic inside service methods instead of at the schema layer
- Custom validators with side effects (DB lookups inside validators couple schema to infrastructure)
- Composing schemas by copy-paste instead of using `extend`, `merge`, or `intersection`

**TypeScript — composable Zod schemas:**
```typescript
// Primitives with business rules
const EmailSchema = z.string().email().toLowerCase().trim();
const MoneySchema = z.number().nonnegative().multipleOf(0.01);
const UUIDSchema = z.string().uuid();

// Composed schemas share primitives — no duplication
const CreateUserSchema = z.object({
  email: EmailSchema,
  balance: MoneySchema.optional(),
});

const UpdateUserSchema = CreateUserSchema.partial().extend({
  id: UUIDSchema,
});

// Cross-field constraint as a refinement
const DateRangeSchema = z.object({
  startDate: z.date(),
  endDate: z.date(),
}).refine(({ startDate, endDate }) => endDate > startDate, {
  message: 'endDate must be after startDate',
  path: ['endDate'],
});
```

**Python — composable Pydantic with custom validators:**
```python
from pydantic import BaseModel, field_validator, model_validator
from typing import Annotated
from pydantic import Field

# Reusable annotated type
PositiveInt = Annotated[int, Field(gt=0)]
EmailStr100 = Annotated[str, Field(pattern=r'^[^@]+@[^@]+\.[^@]+$', max_length=100)]

class DateRange(BaseModel):
    start_date: date
    end_date: date

    @model_validator(mode='after')
    def end_after_start(self) -> 'DateRange':
        if self.end_date <= self.start_date:
            raise ValueError('end_date must be after start_date')
        return self

class Report(DateRange):  # composition via inheritance
    title: str
    item_count: PositiveInt
```

**Go — chained custom validators:**
```go
// Custom validators compose via struct tags
type Product struct {
    SKU   string  `validate:"required,sku_format"`
    Price float64 `validate:"required,gt=0,price_precision"`
}

// Register in init(); test in isolation
func init() {
    _ = validate.RegisterValidation("price_precision", func(fl validator.FieldLevel) bool {
        v := fl.Field().Float()
        return math.Round(v*100)/100 == v // max 2 decimal places
    })
}
```

---

### 9. Validation Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Validate Only at UI** | Front-end validates; back-end trusts the result | Validate at every trust boundary independently |
| **Trust Internal Data** | Skipping validation on data from internal services or the database | Validate all data crossing a service or layer boundary |
| **Stringly-Typed Schemas** | `type: "string"` everywhere; no semantic constraints | Use typed schemas with domain-specific rules (`email`, `uuid`, `positive`) |
| **Validate Only for Format** | Checking `string` type but not length, range, or pattern | Validate all dimensions: type, format, range, presence |
| **Monolithic God Schema** | One 200-field schema for all endpoints | Split into focused schemas per use-case; compose from primitives |
| **Side-Effectful Validators** | DB uniqueness check inside a schema validator | Keep validators pure; enforce uniqueness in the service layer |
| **Silent Coercion** | `z.coerce` or Pydantic defaults masking producer bugs | Use strict parsing at boundaries; reserve coercion for explicit conversion layers |
| **Schema Duplication** | Same shape defined in multiple files with slight drift | Extract shared primitives; compose using `extend`, `merge`, `partial` |
| **Missing Error Context** | `"validation failed"` with no field path | Return per-field error messages with dot-notation paths |
| **Validate-and-Forget** | Input validated, then `any`-cast and passed to inner layers | Propagate the typed result; never re-cast to `any` after validation |

**Stringly-typed schema fix — TypeScript:**
```typescript
// WRONG — string is too broad; accepts anything
const Schema = z.object({
  status: z.string(),
  email: z.string(),
  count: z.string(),
});

// CORRECT — domain constraints encoded in the schema
const Schema = z.object({
  status: z.enum(['active', 'inactive', 'pending']),
  email: z.string().email().max(254),
  count: z.number().int().min(0).max(10_000),
});
```

**Validate-and-forget fix — TypeScript:**
```typescript
// WRONG — type erased after validation; any flows through
function process(raw: unknown) {
  UserSchema.parse(raw);
  doWork(raw as any); // validation result discarded
}

// CORRECT — use the typed result
function process(raw: unknown) {
  const user = UserSchema.parse(raw);
  doWork(user); // typed User — no cast needed
}
```

---

## Cross-References

- `type-system-patterns` — Branded/nominal types for encoding domain rules at the type level; intersection types for composing schemas
- `security-patterns-code-review` — Injection prevention, input sanitization, and trust boundary enforcement in security context
- `error-handling-patterns` — Fail-Fast pattern: validation at boundaries; Result/Either types for propagating validation errors
- `api-rate-limiting-throttling` — Validation of rate-limit headers and throttle configurations at service boundaries
- `review-code-quality-process` — Validation checklist integration into the overall code review workflow
- `detect-code-smells` — "Shotgun Surgery": validation logic scattered across layers indicates a missing centralized schema layer
