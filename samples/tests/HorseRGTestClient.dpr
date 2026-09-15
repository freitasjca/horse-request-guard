program HorseRGTestClient;

{$APPTYPE CONSOLE}

{
  Horse.Middleware.RequestGuard  —  Integration Test Client
  =========================================================
  Destination: horse-request-guard/samples/tests/HorseRGTestClient.dpr

  Requires HorseRGTestServer running on 127.0.0.1:9200 before executing.

  Test matrix (server guard config: AllowedMethods=GET,POST  MaxUrlLength=20
               MaxQueryKeyLen=10  MaxQueryValueLen=15  MaxHeaderCount=10
               MaxBodyBytes=1024  RejectCLWithTE=True):

    01  GET  /ping                         → 200 "pong"        (happy path)
    02  POST /echo  body="hello"           → 200 "hello"       (valid POST)
    03  DELETE /ping                       → 405               (method not in AllowedMethods)
    04  TRACE /ping                        → 405               (TRACE always blocked)
    05  GET  /path/exceeds/twenty/chars    → 414               (URL length 26 > MaxUrlLength 20)
    06  GET  /ping?a_long_key2=v           → 400               (query key > MaxQueryKeyLen)
    07  GET  /ping?k=a_very_long_value     → 400               (query value > MaxQueryValueLen)
    08  POST /echo  body=2000 bytes        → 413               (Content-Length > MaxBodyBytes)
    09  GET  /ping + 11 custom headers     → 431               (header count > MaxHeaderCount)
    10  POST /echo  + CL + TE headers      → 400               (smuggling guard RFC 7230)
    11  POST /echo  empty body             → 200               (no body — body check skipped)
    12  GET  /ping                         → 200               (server still healthy after rejections)
    13  GET  /ping?k=100%25                → 200 "pong"        (encoded % in a query value — decoded once)

  Exit code = number of failed assertions (0 = all passed).
}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Net.CrossHttpClient,
  Net.CrossHttpParams;

const
  BASE_URL   = 'http://127.0.0.1:9200';
  TIMEOUT_MS = 8000;

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ── Helpers ───────────────────────────────────────────────────────────────────

function StreamToStr(AStream: TStream): string;
var
  LBytes: TBytes;
begin
  Result := '';
  if not Assigned(AStream) or (AStream.Size = 0) then Exit;
  AStream.Position := 0;
  SetLength(LBytes, AStream.Size);
  AStream.ReadBuffer(LBytes[0], AStream.Size);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

procedure Check(const AName: string; const APassed: Boolean;
  const ADetail: string = '');
begin
  if APassed then
  begin
    Writeln(Format('  PASS  %s', [AName]));
    Inc(GPassCount);
  end
  else
  begin
    if ADetail <> '' then
      Writeln(Format('  FAIL  %s  [%s]', [AName, ADetail]))
    else
      Writeln(Format('  FAIL  %s', [AName]));
    Inc(GFailCount);
  end;
end;

// ── Synchronous request helper ────────────────────────────────────────────────

type
  TReqResult = record
    StatusCode: Integer;
    Body:       string;
    Response:   ICrossHttpClientResponse;
    TimedOut:   Boolean;
  end;

function DoSync(
  const AClient:  TCrossHttpClient;
  const AMethod:  string;
  const AUrl:     string;
  const AHeaders: THttpHeader;
  const ABody:    TBytes;
  out   AResult:  TReqResult
): Boolean;
var
  LEvent:  TEvent;
  LResult: TReqResult;
begin
  LResult   := Default(TReqResult);
  LEvent    := TEvent.Create(nil, True, False, '');
  try
    AClient.DoRequest(AMethod, AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LResult.StatusCode := AResp.StatusCode;
          LResult.Body       := StreamToStr(AResp.Content);
          LResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    LResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  AResult := LResult;
  Result  := not AResult.TimedOut;
end;

// ── Test suite ────────────────────────────────────────────────────────────────

procedure RunTests(const AClient: TCrossHttpClient);
var
  R:       TReqResult;
  LHdrs:   THttpHeader;
  LBody:   TBytes;
  I:       Integer;

  procedure Section(const ATitle: string);
  begin
    Writeln('');
    Writeln('── ' + ATitle);
  end;

begin

  // ── 01  Happy path: valid GET ────────────────────────────────────────────────
  Section('01  GET /ping  (valid request)');
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('status 200',    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "pong"', R.Body = 'pong',    R.Body);

  // ── 02  Happy path: valid POST with body ────────────────────────────────────
  Section('02  POST /echo body="hello"  (valid POST)');
  DoSync(AClient, 'POST', BASE_URL + '/echo', nil,
    TEncoding.UTF8.GetBytes('hello'), R);
  Check('status 200',      R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "hello"',  R.Body = 'hello',   R.Body);

  // ── 03  Method not in AllowedMethods ────────────────────────────────────────
  Section('03  DELETE /ping  (AllowedMethods = GET, POST — DELETE rejected)');
  DoSync(AClient, 'DELETE', BASE_URL + '/ping', nil, nil, R);
  Check('status 405', R.StatusCode = 405, IntToStr(R.StatusCode));

  // ── 04  TRACE always blocked (maps to mtAny → "" not in any AllowedMethods) ─
  Section('04  TRACE /ping  (always blocked regardless of AllowedMethods)');
  DoSync(AClient, 'TRACE', BASE_URL + '/ping', nil, nil, R);
  Check('status 405', R.StatusCode = 405, IntToStr(R.StatusCode));

  // ── 05  URL path too long (MaxUrlLength = 20) ────────────────────────────────
  //  '/path/exceeds/twenty/chars' = 26 chars > 20
  Section('05  GET /path/exceeds/twenty/chars  (MaxUrlLength = 20)');
  DoSync(AClient, 'GET', BASE_URL + '/path/exceeds/twenty/chars', nil, nil, R);
  Check('status 414', R.StatusCode = 414, IntToStr(R.StatusCode));

  // ── 06  Query key too long (MaxQueryKeyLen = 10) ─────────────────────────────
  //  key "a_long_key2" = 11 chars > 10
  Section('06  GET /ping?a_long_key2=v  (MaxQueryKeyLen = 10)');
  DoSync(AClient, 'GET', BASE_URL + '/ping?a_long_key2=v', nil, nil, R);
  Check('status 400', R.StatusCode = 400, IntToStr(R.StatusCode));

  // ── 07  Query value too long (MaxQueryValueLen = 15) ─────────────────────────
  //  value "a_very_long_value" = 17 chars > 15
  Section('07  GET /ping?k=a_very_long_value  (MaxQueryValueLen = 15)');
  DoSync(AClient, 'GET', BASE_URL + '/ping?k=a_very_long_value', nil, nil, R);
  Check('status 400', R.StatusCode = 400, IntToStr(R.StatusCode));

  // ── 08  Body size exceeds limit (MaxBodyBytes = 1024) ────────────────────────
  //  Send 2000 bytes — Content-Length: 2000 > 1024
  Section('08  POST /echo body=2000 bytes  (MaxBodyBytes = 1024)');
  SetLength(LBody, 2000);
  FillChar(LBody[0], 2000, Ord('A'));
  DoSync(AClient, 'POST', BASE_URL + '/echo', nil, LBody, R);
  Check('status 413', R.StatusCode = 413, IntToStr(R.StatusCode));

  // ── 09  Too many request headers (MaxHeaderCount = 10) ───────────────────────
  //  Add 11 custom headers; combined with Host the total exceeds 10
  Section('09  GET /ping + 11 custom headers  (MaxHeaderCount = 10)');
  LHdrs := THttpHeader.Create;
  try
    for I := 1 to 11 do
      LHdrs.Add('X-Test-' + IntToStr(I), 'value');
    DoSync(AClient, 'GET', BASE_URL + '/ping', LHdrs, nil, R);
    Check('status 431', R.StatusCode = 431, IntToStr(R.StatusCode));
  finally
    LHdrs.Free;
  end;

  // ── 10  CL + TE smuggling guard (RFC 7230 §3.3.3) ───────────────────────────
  //  Present both Content-Length and Transfer-Encoding — guard (or transport
  //  pre-validation) must reject with 400.
  //
  //  IMPORTANT: do NOT use 'chunked' here.  When TE=chunked, CrossSocket's HTTP
  //  parser expects a valid chunked-encoded body (4\r\ntest\r\n0\r\n\r\n).
  //  TCrossHttpClient sends raw bytes, which are not valid chunked frames.
  //  CrossSocket waits forever for the chunked terminator → 8-second client
  //  timeout → stale callback → corrupts test 11 via freed-LEvent reuse.
  //
  //  'identity' means "no transformation": CrossSocket reads the body by
  //  Content-Length (auto-added by TCrossHttpClient), fully parses the request,
  //  then TRequestBridge.CheckSmuggling sees CL + TE and rejects with 400.
  Section('10  POST /echo with Content-Length AND Transfer-Encoding  (smuggling guard)');
  LHdrs := THttpHeader.Create;
  try
    LHdrs.Add('Transfer-Encoding', 'identity');
    DoSync(AClient, 'POST', BASE_URL + '/echo', LHdrs,
      TEncoding.UTF8.GetBytes('test'), R);
    Check('status 400', R.StatusCode = 400, IntToStr(R.StatusCode));
  finally
    LHdrs.Free;
  end;

  // ── 11  Empty POST body — no Content-Length, no body check triggered ─────────
  Section('11  POST /echo  empty body  (no body size check without Content-Length)');
  DoSync(AClient, 'POST', BASE_URL + '/echo', nil, nil, R);
  Check('status 200', R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body empty', R.Body = '', R.Body);

  // ── 12  Server still healthy after all rejections ────────────────────────────
  Section('12  GET /ping  (server healthy after all prior rejections)');
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('status 200',    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "pong"', R.Body = 'pong',    R.Body);

  // ── 13  Encoded '%' in a query value (FIX-RG-DECODE-ONCE-1) ─────────────────
  //  k=100%25 is stored as "100%" — already decoded once.  The guard's query
  //  length check used to read Query.Content, which on Horse 3.3.x decodes a
  //  second time: "100%" ends in a bare '%' → EConvertError "Error decoding URL
  //  style (%XX)..." → 500 before the route ran.  Only distinguishes the fix on
  //  a Horse without HashLoad/horse#570 (on a patched Horse, Content no longer
  //  decodes and the old code passes too).
  //  TCrossHttpClient re-encodes the query, but a fully percent-encoded value
  //  survives byte-for-byte.
  Section('13  GET /ping?k=100%25  (encoded % in a query value — decoded once)');
  DoSync(AClient, 'GET', BASE_URL + '/ping?k=100%25', nil, nil, R);
  Check('status 200',    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "pong"', R.Body = 'pong',    R.Body);

end;

// ── Entry point ───────────────────────────────────────────────────────────────

var
  AClient: TCrossHttpClient;
begin
  Writeln('Horse RequestGuard — Integration Tests');
  Writeln('Server: ' + BASE_URL);
  Writeln(StringOfChar('─', 50));

  AClient := TCrossHttpClient.Create(2);
  try
    RunTests(AClient);
  finally
    AClient.Free;
  end;

  Writeln('');
  Writeln(StringOfChar('─', 50));
  Writeln(Format('Results: %d passed  %d failed  %d total',
    [GPassCount, GFailCount, GPassCount + GFailCount]));

  ExitCode := GFailCount;
end.
