# horse-request-guard

> Input validation middleware for the [Horse](https://github.com/HashLoad/horse) web framework.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Delphi](https://img.shields.io/badge/Delphi-10.4%2B-red.svg)](https://www.embarcadero.com/products/delphi)
[![FPC](https://img.shields.io/badge/FPC-3.2%2B-blue.svg)](https://www.freepascal.org/)
[![Horse](https://img.shields.io/badge/Horse-3.x-blue.svg)](https://github.com/HashLoad/horse)
[![Boss](https://img.shields.io/badge/Boss-compatible-green.svg)](https://github.com/HashLoad/boss)

---

## What it does

Registers a single middleware that validates each incoming request **before it reaches your route handlers**.  On the first failing check the request is rejected with a specific HTTP status code and the middleware chain stops.

| # | Check | Failure status |
|---|---|:---:|
| 1 | HTTP method in `AllowedMethods` | `405` |
| 2 | TRACE / CONNECT blocked unconditionally | `405` |
| 3 | `Host` header present and printable (no control characters) | `400` |
| 4 | `Host` matches `AllowedHosts` (if configured) | `400` |
| 5 | `Content-Length` and `Transfer-Encoding` not both present (RFC 7230 §3.3.3) | `400` |
| 6 | Request path ≤ `MaxUrlLength` | `414` |
| 7 | Each query-string key ≤ `MaxQueryKeyLen`, value ≤ `MaxQueryValueLen` | `400` |
| 8 | Number of request headers ≤ `MaxHeaderCount` | `431` |
| 9 | Declared `Content-Length` ≤ `MaxBodyBytes` | `413` |

---

## Installation

```bash
boss install github.com/freitasjca/horse-request-guard
```

Or add to your project's `boss.json`:

```json
{
  "dependencies": {
    "github.com/freitasjca/horse-request-guard": ">=1.0.0"
  }
}
```

---

## Usage

### Default configuration

```pascal
uses
  Horse,
  Horse.Middleware.RequestGuard;

begin
  THorse.Use(THorseRequestGuard.New);   // must be the first middleware

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);
end.
```

### Custom configuration

```pascal
uses
  Horse,
  Horse.Middleware.RequestGuard;

var
  LGuardConfig: THorseRequestGuardConfig;
begin
  LGuardConfig                := THorseRequestGuardConfig.Default;
  LGuardConfig.AllowedMethods := ['GET', 'POST'];          // restrict to two verbs
  LGuardConfig.AllowedHosts   := ['api.example.com'];      // lock to one hostname
  LGuardConfig.MaxBodyBytes   := 1 * 1024 * 1024;          // 1 MB body limit

  THorse.Use(THorseRequestGuard.New(LGuardConfig));

  THorse.Listen(9000);
end.
```

---

## Configuration reference

```pascal
type
  THorseRequestGuardConfig = record
    AllowedMethods:   TArray<string>;  // default: GET POST PUT DELETE PATCH HEAD OPTIONS
    AllowedHosts:     TArray<string>;  // default: [] = accept any host
    MaxUrlLength:     Integer;         // default: 8 192 characters  (0 = unlimited)
    MaxQueryKeyLen:   Integer;         // default: 2 048 characters  (0 = unlimited)
    MaxQueryValueLen: Integer;         // default: 2 048 characters  (0 = unlimited)
    MaxHeaderCount:   Integer;         // default: 100 headers       (0 = unlimited)
    MaxBodyBytes:     Int64;           // default: 4 194 304 bytes   (0 = unlimited)
    RejectCLWithTE:   Boolean;         // default: True
    class function Default: THorseRequestGuardConfig; static;
  end;
```

| Field | Default | Description |
|---|---|---|
| `AllowedMethods` | `GET POST PUT DELETE PATCH HEAD OPTIONS` | Accepted HTTP verbs.  TRACE and CONNECT are always rejected regardless of this list. |
| `AllowedHosts` | *(empty — any)* | If non-empty, the `Host` header must match one of these values (case-insensitive). |
| `MaxUrlLength` | `8192` | Maximum length of the decoded request path in characters. |
| `MaxQueryKeyLen` | `2048` | Maximum length of a single query-string key. |
| `MaxQueryValueLen` | `2048` | Maximum length of a single query-string value. |
| `MaxHeaderCount` | `100` | Maximum number of request headers. |
| `MaxBodyBytes` | `4194304` (4 MB) | Maximum value accepted in the `Content-Length` header. |
| `RejectCLWithTE` | `True` | Reject requests that carry both `Content-Length` and `Transfer-Encoding` (request-smuggling guard, RFC 7230 §3.3.3). |

---

## Provider compatibility

| Feature | Horse + Indy | Horse + CrossSocket |
|---|:---:|:---:|
| Method allowlist (checks 1–2) | **this middleware** | ✓ pre-pipeline ¹ |
| Host validation (checks 3–4) | **this middleware** | ✓ pre-pipeline ¹ |
| CL+TE smuggling guard (check 5) | **this middleware** | ✓ pre-pipeline ¹ |
| Size limits (checks 6–9) | **this middleware** | ✓ pre-pipeline ¹ |

¹ The [Horse.Provider.CrossSocket](https://github.com/freitasjca/horse-provider-crosssocket) provider enforces all of these checks **before** the request enters the Horse pipeline via `TRequestBridge.Populate`.  Registering this middleware alongside CrossSocket is safe (defence in depth) but redundant — invalid requests never reach the middleware on the CrossSocket path.

**On Indy, this middleware is the only line of defence.**  Register it as the first middleware so that invalid requests are rejected before any application logic runs.

### FPC note

On Free Pascal, `TMethodType` does not include `mtOptions`.  `OPTIONS` requests arrive as `mtAny` (unrecognised method) and will be rejected with `405` if `OPTIONS` is not also listed in `AllowedMethods` *and* the runtime can distinguish it from other unknown methods — which it cannot on FPC.  If you require `OPTIONS` support under FPC + Indy, remove `OPTIONS` from the check by either clearing `AllowedMethods` (disables the method check entirely) or accepting the limitation.

---

## License

MIT — see [LICENSE](LICENSE).
