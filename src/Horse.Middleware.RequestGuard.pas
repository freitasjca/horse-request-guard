unit Horse.Middleware.RequestGuard;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Middleware.RequestGuard
//  Input validation middleware: method allowlist, Host check, CL+TE smuggling
//  guard, URL/query/header size limits, body size limit.
//
//  Provider-agnostic — works with any Horse provider (Indy, CrossSocket, etc.)
//  On CrossSocket these checks are already enforced pre-pipeline by
//  TRequestBridge.Populate; registering this middleware there is redundant but
//  harmless (defence in depth).  On Indy this is the only line of defence.
//
//  Usage:
//    THorse.Use(THorseRequestGuard.New);               // default config
//    THorse.Use(THorseRequestGuard.New(Config));        // custom config
//
//  Method check uses Req.RawWebRequest.Method (the raw wire string) rather than
//  Req.MethodType (TMethodType enum).  TMethodType collapses OPTIONS, TRACE,
//  and CONNECT into mtAny, making them indistinguishable at enum level.
//  The raw string correctly differentiates all three — same approach as
//  Horse.CORS (Req.RawWebRequest.Method = 'OPTIONS').
// ============================================================================


(*
Checks performed (in order, short-circuits on first failure):

  1+2. Method in AllowedMethods?         → 405 Method Not Allowed
       (TRACE and CONNECT are rejected because they are absent from the
       default list; OPTIONS passes because 'OPTIONS' is in the default list)
  3. Host present and printable?         → 400 Bad Request
  4. Host in AllowedHosts? (if set)      → 400
  5. CL + TE both present?               → 400 (RFC 7230 smuggling)
  6. URL length > MaxUrlLength?          → 414 URI Too Long
  7. Query key/value > limits?           → 400
  8. Header count > MaxHeaderCount?      → 431 Request Header Fields Too Large
  9. Body size > MaxBodyBytes?           → 413 Content Too Large

  Note on check 9: on Indy the body is already buffered — this prevents the
  handler from processing an oversized body, but not from receiving it.

*)

interface

uses
  Horse.Request,
  Horse.Response,
  Horse.Callback;

type
  THorseRequestGuardConfig = record
    /// HTTP methods the server accepts.  Default: GET POST PUT DELETE PATCH HEAD OPTIONS.
    AllowedMethods:   TArray<string>;
    /// Allowed Host header values.  Empty = accept any host.
    AllowedHosts:     TArray<string>;
    /// Maximum request-path length in characters (0 = unlimited).  Default: 8192.
    MaxUrlLength:     Integer;
    /// Maximum query-string key length in characters (0 = unlimited).  Default: 2048.
    MaxQueryKeyLen:   Integer;
    /// Maximum query-string value length in characters (0 = unlimited).  Default: 2048.
    MaxQueryValueLen: Integer;
    /// Maximum number of request headers (0 = unlimited).  Default: 100.
    MaxHeaderCount:   Integer;
    /// Maximum Content-Length in bytes (0 = unlimited).  Default: 4 MB.
    MaxBodyBytes:     Int64;
    /// Reject requests that carry both Content-Length and Transfer-Encoding
    /// (RFC 7230 §3.3.3 smuggling guard).  Default: True.
    RejectCLWithTE:   Boolean;

    class function Default: THorseRequestGuardConfig; static;
  end;

  THorseRequestGuard = class
  public
    class function New: THorseCallback; overload;
    class function New(const AConfig: THorseRequestGuardConfig): THorseCallback; overload;
  end;

implementation

// On FPC without HORSE_FPC_FUNCTIONREFERENCES, THorseCallback is a plain
// (Register calling convention) procedure type — it accepts neither anonymous
// procedures (no FUNCTIONREFERENCES mode) nor method pointers (wrong calling
// convention). The only signature it accepts is a plain unit-scope procedure.
//
// That is the same constraint the upstream Horse.CORS middleware works around
// by storing its config in a unit-level var and exposing a plain procedure
// (`CORS`). We do exactly the same here: GRequestGuardConfig holds the
// configuration that New() last installed, and RequestGuardProc runs the
// validation pipeline against it.
//
// Trade-off: configuration is process-wide. A second New(AConfig) call
// overwrites the first. This matches Horse.CORS semantics and works on every
// Pascal compiler (Delphi, FPC stable, FPC with or without FUNCTIONREFERENCES).

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Horse.Proc,
  Horse.Exception.Interrupted;

var
  GRequestGuardConfig: THorseRequestGuardConfig;
  GRequestGuardInstalled: Boolean;

{ THorseRequestGuardConfig }

class function THorseRequestGuardConfig.Default: THorseRequestGuardConfig;
begin
  Result.AllowedMethods   := ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'];
  Result.AllowedHosts     := [];
  Result.MaxUrlLength     := 8192;
  Result.MaxQueryKeyLen   := 2048;
  Result.MaxQueryValueLen := 2048;
  Result.MaxHeaderCount   := 100;
  Result.MaxBodyBytes     := 4 * 1024 * 1024; // 4 MB
  Result.RejectCLWithTE   := True;
end;

{ Helpers — file-scope, not exported }

function StrInList(const AStr: string; const AList: TArray<string>): Boolean;
var
  LItem: string;
begin
  Result := False;
  for LItem in AList do
    if SameText(LItem, AStr) then
    begin
      Result := True;
      Exit;
    end;
end;

function IsPrintable(const AStr: string): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(AStr) do
    if Ord(AStr[I]) < 32 then
    begin
      Result := False;
      Exit;
    end;
end;

{ Plain unit-scope procedure — assignable to THorseCallback on every
  Pascal flavor (Delphi reference-to, FPC plain procedure, FPC FUNCTIONREFERENCES). }
procedure RequestGuardProc(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LMethod:  string;
  LHost:    string;
  LCL:      string;
  LCLBytes: Int64;
  LContent: TStrings;
  I:        Integer;
  LEntry:   string;
  LEqPos:   Integer;
  LKey:     string;
  LVal:     string;
begin
  if not GRequestGuardInstalled then
  begin
    ANext;
    Exit;
  end;

  // ── 1 + 2. Method check ─────────────────────────────────────────────
  // Uses the raw wire string (same approach as Horse.CORS) so that OPTIONS,
  // TRACE, and CONNECT are all distinguishable — TMethodType maps all three
  // to mtAny and cannot tell them apart.
  if Length(GRequestGuardConfig.AllowedMethods) > 0 then
  begin
    LMethod := AReq.RawWebRequest.Method;
    if not StrInList(LMethod, GRequestGuardConfig.AllowedMethods) then
    begin
      ARes.Status(405).Send('Method Not Allowed');
      raise EHorseCallbackInterrupted.Create;
    end;
  end;

  // ── 3. Host present and printable ───────────────────────────────────
  LHost := AReq.Host;
  if (LHost = '') or not IsPrintable(LHost) then
  begin
    ARes.Status(400).Send('Bad Request: missing or invalid Host header');
    raise EHorseCallbackInterrupted.Create;
  end;

  // ── 4. Host in AllowedHosts (if configured) ─────────────────────────
  if (Length(GRequestGuardConfig.AllowedHosts) > 0) and
     not StrInList(LHost, GRequestGuardConfig.AllowedHosts) then
  begin
    ARes.Status(400).Send('Bad Request: Host not permitted');
    raise EHorseCallbackInterrupted.Create;
  end;

  // ── 5. CL + TE smuggling guard (RFC 7230 §3.3.3) ────────────────────
  if GRequestGuardConfig.RejectCLWithTE and
     AReq.Headers.ContainsKey('Content-Length') and
     AReq.Headers.ContainsKey('Transfer-Encoding') then
  begin
    ARes.Status(400).Send('Bad Request: ambiguous Content-Length with Transfer-Encoding');
    raise EHorseCallbackInterrupted.Create;
  end;

  // ── 6. URL (path) length ────────────────────────────────────────────
  if (GRequestGuardConfig.MaxUrlLength > 0) and
     (Length(AReq.PathInfo) > GRequestGuardConfig.MaxUrlLength) then
  begin
    ARes.Status(414).Send('URI Too Long');
    raise EHorseCallbackInterrupted.Create;
  end;

  // ── 7. Query key / value length ─────────────────────────────────────
  if (GRequestGuardConfig.MaxQueryKeyLen > 0) or
     (GRequestGuardConfig.MaxQueryValueLen > 0) then
  begin
    LContent := AReq.Query.Content;
    for I := 0 to LContent.Count - 1 do
    begin
      LEntry := LContent.Strings[I];
      LEqPos := Pos('=', LEntry);
      if LEqPos > 0 then
      begin
        LKey := Copy(LEntry, 1, LEqPos - 1);
        LVal := Copy(LEntry, LEqPos + 1, MaxInt);
      end
      else
      begin
        LKey := LEntry;
        LVal := '';
      end;

      if (GRequestGuardConfig.MaxQueryKeyLen > 0) and
         (Length(LKey) > GRequestGuardConfig.MaxQueryKeyLen) then
      begin
        ARes.Status(400).Send('Bad Request: query parameter key too long');
        raise EHorseCallbackInterrupted.Create;
      end;
      if (GRequestGuardConfig.MaxQueryValueLen > 0) and
         (Length(LVal) > GRequestGuardConfig.MaxQueryValueLen) then
      begin
        ARes.Status(400).Send('Bad Request: query parameter value too long');
        raise EHorseCallbackInterrupted.Create;
      end;
    end;
  end;

  // ── 8. Header count ─────────────────────────────────────────────────
  if (GRequestGuardConfig.MaxHeaderCount > 0) and
     (AReq.Headers.Count > GRequestGuardConfig.MaxHeaderCount) then
  begin
    ARes.Status(431).Send('Request Header Fields Too Large');
    raise EHorseCallbackInterrupted.Create;
  end;

  // ── 9. Declared body size (Content-Length header) ───────────────────
  // Pipeline-level guard on the declared size. On Indy the body has already
  // been received; this prevents handlers from processing oversized payloads.
  // On CrossSocket / mORMot the transport already enforces the limit
  // pre-pipeline; this check is redundant but harmless.
  if GRequestGuardConfig.MaxBodyBytes > 0 then
  begin
    LCL := AReq.Headers['Content-Length'];
    if LCL <> '' then
    begin
      LCLBytes := StrToInt64Def(LCL, 0);
      if LCLBytes > GRequestGuardConfig.MaxBodyBytes then
      begin
        ARes.Status(413).Send('Payload Too Large');
        raise EHorseCallbackInterrupted.Create;
      end;
    end;
  end;

  ANext;
end;

{ THorseRequestGuard }

class function THorseRequestGuard.New: THorseCallback;
begin
  Result := New(THorseRequestGuardConfig.Default);
end;

class function THorseRequestGuard.New(const AConfig: THorseRequestGuardConfig): THorseCallback;
begin
  GRequestGuardConfig    := AConfig;
  GRequestGuardInstalled := True;
  // No `@` here — Delphi promotes a plain procedure to its reference-to type
  // automatically; FPC's {$MODE DELPHI} accepts the same form. Adding `@` would
  // force a raw Pointer and trigger a type-mismatch on Delphi's THorseCallback.
  Result                 := RequestGuardProc;
end;

initialization
  GRequestGuardInstalled := False;

end.
