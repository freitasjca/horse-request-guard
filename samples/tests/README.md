# Integration Test Projects — horse-request-guard

Two console programs that together form the integration test suite.

| Program | Role |
|---|---|
| `HorseRGTestServer.dpr` | HTTP server on `127.0.0.1:9200` — start first |
| `HorseRGTestClient.dpr` | Test runner — exits with `0` (all pass) or `N` (N failures) |

---

## Creating the .dproj files

The `.dpr` sources are committed. The `.dproj` project files must be created in the Delphi IDE. Create two separate console application projects with the settings below.

### HorseRGTestServer.dproj

**Project Options → Delphi Compiler → Conditional defines:**
```
HORSE_CROSSSOCKET
```

**Project Options → Delphi Compiler → Search path** (relative to this file's directory):
```
..\..\modules\horse\src
..\..\modules\Delphi-Cross-Socket\Net
..\..\modules\Delphi-Cross-Socket\Utils
..\..\modules\Delphi-Cross-Socket\OpenSSL
..\..\modules\horse-provider-crosssocket\src
..\..\src
```

**Project Options → Delphi Compiler → Output directory:**
```
$(Platform)\$(Config)
```

**App type:** Console application (`{$APPTYPE CONSOLE}` is already in the .dpr)

---

### HorseRGTestClient.dproj

**Project Options → Delphi Compiler → Conditional defines:** *(none required)*

**Project Options → Delphi Compiler → Search path:**
```
..\..\modules\Delphi-Cross-Socket\Net
..\..\modules\Delphi-Cross-Socket\Utils
..\..\modules\Delphi-Cross-Socket\OpenSSL
```

**Project Options → Delphi Compiler → Output directory:**
```
$(Platform)\$(Config)
```

**App type:** Console application

---

## Running manually

```bat
cd horse-request-guard

REM 1. Install dependencies (once)
boss install

REM 2. Build both projects in the Delphi IDE (Win64 Release)

REM 3. Start the server (leave this window open)
samples\tests\Win64\Release\HorseRGTestServer.exe

REM 4. In a second window: run the client
samples\tests\Win64\Release\HorseRGTestClient.exe
REM Exit code 0 = all tests passed; N = N failures
echo Exit code: %ERRORLEVEL%
```

---

## Server guard configuration

The server registers `THorseRequestGuard` with a deliberately restrictive custom config designed to make every validation check reachable from short, predictable test requests:

| Field | Value | Tests |
|---|---|---|
| `AllowedMethods` | `['GET', 'POST']` | 03, 04 |
| `MaxUrlLength` | `20` | 05 |
| `MaxQueryKeyLen` | `10` | 06 |
| `MaxQueryValueLen` | `15` | 07 |
| `MaxBodyBytes` | `1024` | 08 |
| `MaxHeaderCount` | `10` | 09 |
| `RejectCLWithTE` | `True` | 10 |
| `AllowedHosts` | `[]` (any) | — |

---

## Test coverage

| # | Method | URL / condition | Expected | What is tested |
|---|---|---|---|---|
| 01 | GET | `/ping` | 200 "pong" | Valid GET — all checks pass |
| 02 | POST | `/echo` body="hello" | 200 "hello" | Valid POST with body |
| 03 | DELETE | `/ping` | 405 | Method not in AllowedMethods |
| 04 | TRACE | `/ping` | 405 | TRACE not in AllowedMethods |
| 05 | GET | `/path/exceeds/twenty` (21 chars) | 414 | URL length > MaxUrlLength |
| 06 | GET | `/ping?a_long_key2=v` (key=11 chars) | 400 | Query key > MaxQueryKeyLen |
| 07 | GET | `/ping?k=a_very_long_value` (value=17 chars) | 400 | Query value > MaxQueryValueLen |
| 08 | POST | `/echo` body=2000 bytes | 413 | Content-Length > MaxBodyBytes |
| 09 | GET | `/ping` + 11 custom headers | 431 | Header count > MaxHeaderCount |
| 10 | POST | `/echo` with Content-Length AND Transfer-Encoding | 400 | RFC 7230 smuggling guard |
| 11 | POST | `/echo` empty body (no Content-Length) | 200 | Body check skipped when no Content-Length |
| 12 | GET | `/ping` | 200 | Server healthy after all prior rejections |
| 13 | GET | `/ping?k=100%25` | 200 "pong" | An encoded `%` in a query value is decoded once — no 500 |

### Notes on specific tests

**Test 04 (TRACE):** `TCrossHttpClient` sends the method string verbatim, and the guard compares that string (`Req.RawWebRequest.Method`) with `AllowedMethods`. TRACE is not in the server's list (GET, POST), so it is rejected with 405. It is not blocked unconditionally: a list that includes TRACE, or an empty list, lets it through.

**Test 10 (CL + TE):** On the CrossSocket path, `TRequestBridge.Populate` also enforces this rule pre-pipeline. The test verifies the end-to-end rejection (400) regardless of which layer enforces it. On the Indy path, the middleware is the only enforcer.

**Test 13 (encoded `%`):** The query value `100%25` is stored as `100%`, already decoded. The query length check (7) used to read `Query.Content`, which on Horse 3.3.0–3.3.5 decodes every value a second time; `100%` ends in a bare `%`, so that raised `EConvertError` ("Error decoding URL style (%XX) encoded string...") and the request failed with 500 before any route ran. The check now iterates `Query.Dictionary`, which holds the stored pairs. The test only tells the two versions apart on a Horse without [HashLoad/horse#570](https://github.com/HashLoad/horse/pull/570) — `boss install` resolves upstream HashLoad/horse, which is that case.

**Test 11 (empty POST):** The guard's body-size check reads the `Content-Length` header. When no body is sent, the client sends no `Content-Length`, so the guard skips the check. The handler receives an empty body and responds 200.
