program HorseRGTestServer;

{$APPTYPE CONSOLE}

{
  Horse.Middleware.RequestGuard  —  Integration Test Server
  =========================================================
  Destination: horse-request-guard/samples/tests/HorseRGTestServer.dpr

  Transport: CrossSocket (define HORSE_CROSSSOCKET in the project options)
             or Indy/Console (default when HORSE_CROSSSOCKET is not defined).
             All 13 tests pass with either provider.

  Port: 9200

  Registers THorseRequestGuard with a deliberately restrictive custom config
  so that every validation check can be exercised by the test client:

    AllowedMethods   = ['GET', 'POST']    tests 03 (DELETE) + 04 (TRACE)
    MaxUrlLength     = 20                 test 05
    MaxQueryKeyLen   = 10                 test 06
    MaxQueryValueLen = 15                 test 07
    MaxHeaderCount   = 10                 test 09
    MaxBodyBytes     = 1024               test 08
    RejectCLWithTE   = True               test 10

  Routes:
    GET  /ping          health check
    POST /echo          echoes request body as plain text
}

uses
  System.SysUtils,
  System.Classes,
  Horse,
  Horse.Commons,
{$IFDEF HORSE_CROSSSOCKET}
  Horse.Provider.CrossSocket,
{$ENDIF}
  Horse.Middleware.RequestGuard;

const
  TEST_PORT = 9200;

procedure RegisterRoutesAndMiddleware;
var
  LConfig: THorseRequestGuardConfig;
begin
  // ── RequestGuard — restrictive config for full check coverage ────────────────
  LConfig                 := THorseRequestGuardConfig.Default;
  LConfig.AllowedMethods  := ['GET', 'POST'];
  LConfig.MaxUrlLength    := 20;
  LConfig.MaxQueryKeyLen  := 10;
  LConfig.MaxQueryValueLen := 15;
  LConfig.MaxHeaderCount  := 10;
  LConfig.MaxBodyBytes    := 1024;
  LConfig.RejectCLWithTE  := True;

  THorse.Use(THorseRequestGuard.New(LConfig));

  // ── Routes ───────────────────────────────────────────────────────────────────

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end
  );

  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send(Req.Body);
    end
  );
end;

begin
  try
    RegisterRoutesAndMiddleware;
{$IFDEF HORSE_CROSSSOCKET}
    THorse.Listen(TEST_PORT);
    Writeln(Format('[HorseRGTest] Server listening on http://127.0.0.1:%d  [CrossSocket]',
      [TEST_PORT]));
{$ELSE}
    THorse.Listen(TEST_PORT);
    Writeln(Format('[HorseRGTest] Server listening on http://127.0.0.1:%d  [Indy/Console]',
      [TEST_PORT]));
{$ENDIF}
    Writeln('[HorseRGTest] Run HorseRGTestClient to execute the test suite.');
    Writeln('[HorseRGTest] Press ENTER to stop...');
    Readln;
  except
    on E: Exception do
    begin
      Writeln('[HorseRGTest] Fatal: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
