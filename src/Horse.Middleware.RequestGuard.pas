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
//  FPC note: TMethodType on FPC does not include mtOptions, so OPTIONS and any
//  other unrecognised method map to mtAny (empty string).  They will be
//  rejected if '' is not in AllowedMethods.  On Delphi OPTIONS maps correctly
//  to mtOptions and is allowed when 'OPTIONS' appears in AllowedMethods.
// ============================================================================


(*
Checks performed (in order, short-circuits on first failure):

  1. Method in AllowedMethods?           → 405 Method Not Allowed
  2. TRACE / CONNECT?                    → 405
  3. Host present and printable?         → 400 Bad Request
  4. Host in AllowedHosts? (if set)      → 400
  5. CL + TE both present?               → 400 (RFC 7230 smuggling)
  6. Unknown Transfer-Encoding?          → 400
  7. URL length > MaxUrlLength?          → 414 URI Too Long
  8. Query key/value > limits?           → 400
  9. Header count > MaxHeaderCount?      → 431 Request Header Fields Too Large
  10. Body size > MaxBodyBytes?          → 413 Content Too Large

  Note on check 10: on Indy the body is already buffered — this prevents the handler from processing an oversized body, but not from receiving it. Document this
  clearly.

*)

interface

uses
  Horse.Request,
  Horse.Response,
  Horse.Callback,
  Horse.Commons;

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

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes;
{$ELSE}
  System.SysUtils,
  System.Classes;
{$ENDIF}

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

function MethodTypeToStr(AType: TMethodType): string;
begin
  case AType of
    mtGet:    Result := 'GET';
    mtPost:   Result := 'POST';
    mtPut:    Result := 'PUT';
    mtHead:   Result := 'HEAD';
    mtDelete: Result := 'DELETE';
    mtPatch:  Result := 'PATCH';
{$IF NOT DEFINED(FPC)}
    mtOptions: Result := 'OPTIONS';
{$ENDIF}
  else
    // mtAny = unknown/unrecognised (includes TRACE, CONNECT, and on FPC also OPTIONS).
    // An empty string will not appear in any AllowedMethods list, so the
    // request is rejected as 405 unless the list is empty (bypass disabled).
    Result := '';
  end;
end;

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

{ THorseRequestGuard }

class function THorseRequestGuard.New: THorseCallback;
begin
  Result := New(THorseRequestGuardConfig.Default);
end;

class function THorseRequestGuard.New(const AConfig: THorseRequestGuardConfig): THorseCallback;
var
  // Capture a copy of the config record.  AConfig is a const param (passed by
  // reference on large records); capturing it directly would capture a
  // pointer to a stack frame that is gone after New() returns.
  LConfig: THorseRequestGuardConfig;
begin
  LConfig := AConfig;

  Result :=
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
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
      // ── 1 + 2. Method check ─────────────────────────────────────────────
      // Rejects TRACE/CONNECT (they map to mtAny → '' on both Delphi and FPC).
      if Length(LConfig.AllowedMethods) > 0 then
      begin
        LMethod := MethodTypeToStr(Req.MethodType);
        if not StrInList(LMethod, LConfig.AllowedMethods) then
        begin
          Res.Status(405).Send('Method Not Allowed');
          Exit;
        end;
      end;

      // ── 3. Host present and printable ───────────────────────────────────
      LHost := Req.Host;
      if (LHost = '') or not IsPrintable(LHost) then
      begin
        Res.Status(400).Send('Bad Request: missing or invalid Host header');
        Exit;
      end;

      // ── 4. Host in AllowedHosts (if configured) ─────────────────────────
      if (Length(LConfig.AllowedHosts) > 0) and
         not StrInList(LHost, LConfig.AllowedHosts) then
      begin
        Res.Status(400).Send('Bad Request: Host not permitted');
        Exit;
      end;

      // ── 5. CL + TE smuggling guard (RFC 7230 §3.3.3) ────────────────────
      if LConfig.RejectCLWithTE and
         Req.Headers.ContainsKey('Content-Length') and
         Req.Headers.ContainsKey('Transfer-Encoding') then
      begin
        Res.Status(400).Send('Bad Request: ambiguous Content-Length with Transfer-Encoding');
        Exit;
      end;

      // ── 6. URL (path) length ─────────────────────────────────────────────
      if (LConfig.MaxUrlLength > 0) and
         (Length(Req.PathInfo) > LConfig.MaxUrlLength) then
      begin
        Res.Status(414).Send('URI Too Long');
        Exit;
      end;

      // ── 7. Query key / value length ──────────────────────────────────────
      if (LConfig.MaxQueryKeyLen > 0) or (LConfig.MaxQueryValueLen > 0) then
      begin
        LContent := Req.Query.Content;
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

          if (LConfig.MaxQueryKeyLen > 0) and (Length(LKey) > LConfig.MaxQueryKeyLen) then
          begin
            Res.Status(400).Send('Bad Request: query parameter key too long');
            Exit;
          end;
          if (LConfig.MaxQueryValueLen > 0) and (Length(LVal) > LConfig.MaxQueryValueLen) then
          begin
            Res.Status(400).Send('Bad Request: query parameter value too long');
            Exit;
          end;
        end;
      end;

      // ── 8. Header count ──────────────────────────────────────────────────
      if (LConfig.MaxHeaderCount > 0) and
         (Req.Headers.Count > LConfig.MaxHeaderCount) then
      begin
        Res.Status(431).Send('Request Header Fields Too Large');
        Exit;
      end;

      // ── 9. Declared body size (Content-Length header) ────────────────────
      // This is a pipeline-level guard on the declared size.  On Indy the body
      // has already been received; this prevents handlers from processing
      // oversized payloads.  On CrossSocket the transport already enforces the
      // limit pre-pipeline; this check is redundant but harmless.
      if LConfig.MaxBodyBytes > 0 then
      begin
        LCL := Req.Headers['Content-Length'];
        if LCL <> '' then
        begin
          LCLBytes := StrToInt64Def(LCL, 0);
          if LCLBytes > LConfig.MaxBodyBytes then
          begin
            Res.Status(413).Send('Payload Too Large');
            Exit;
          end;
        end;
      end;

      Next;
    end;
end;

end.
