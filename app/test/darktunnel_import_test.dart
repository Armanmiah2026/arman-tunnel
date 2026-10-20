import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapdark_tunnel/models/server_config.dart';
import 'package:snapdark_tunnel/utils/darktunnel_codec.dart';

void main() {
  test('darktunnel SSL(TCP) vless imports as tcp+tls+sni with directSni', () {
    const link =
        'darktunnel://eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoiU1NMLTg0NDMteW91cl9jaGFubmVsIiwidmxlc3NUdW5uZWxDb25maWciOnsidjJyYXlDb25maWciOnsiaG9zdCI6InNneC50ZHotc2VydmVyLnN0b3JlIiwicG9ydCI6ODQ0MywidXVpZCI6IjYyNWQ5ZGUzLTI0ODAtNGY4NC1hMzNmLWQzMGQwOWZjZGJiYiIsInRyYW5zcG9ydE5ldHdvcmsiOiJUY3AiLCJzZXJ2ZXJOYW1lSW5kaWNhdGlvbiI6IkZhY2Vib29rLmNvbSIsIndzUGF0aCI6Ii9AeW91cl9jaGFubmVsIiwid3NIZWFkZXJIb3N0Ijoic2d4LnRkei1zZXJ2ZXIuc3RvcmUifSwiaW5qZWN0Q29uZmlnIjp7InBheWxvYWQiOiIifX19';
    final c = ServerConfig.fromDarkTunnelUri(link);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vless);
    expect(c.transport, TransportType.tcp, reason: 'Tcp stays TCP');
    expect(c.security, SecurityType.tls);
    expect(c.sni, 'Facebook.com');
    expect(c.host, 'sgx.tdz-server.store');
    expect(c.address, 'sgx.tdz-server.store');
    expect(c.port, 8443);
    expect(c.uuid, '625d9de3-2480-4f84-a33f-d30d09fcdbbb');
    // A TCP config with a path is invalid — wsPath must NOT leak in.
    expect(c.path, isNull);
    // Blank payload + SNI → the injector's TLS/SNI wrap.
    // Blank payload + SNI → the injector's TLS/SNI wrap.
    expect(c.injectMode, InjectMode.directSni);
  });

  test('darktunnel VLESS ws without transportNetwork: wsPath means WebSocket', () {
    // The user's failing config: v2rayConfig has NO transportNetwork, only
    // wsPath + wsHeaderHost. DarkTunnel treats wsPath presence as WS.
    const link =
        'darktunnel://eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoiNDkwIC0gTlRMUy1aLXJha2liIiwidmxlc3NUdW5uZWxDb25maWciOnsidjJyYXlDb25maWciOnsiaG9zdCI6InNneC50ZHotc2VydmVyLnN0b3JlIiwicG9ydCI6NDkwLCJ1dWlkIjoiMGJiNmNmYmQtM2EyNS00NmU2LWI1MGEtM2I1YTI1YWVlM2ZmIiwidGxzIjpmYWxzZSwid3NQYXRoIjoiL0B5b3VyX2NoYW5uZWwiLCJ3c0hlYWRlckhvc3QiOiJzZ3gudGR6LXNlcnZlci5zdG9yZSJ9LCJpbmplY3RDb25maWciOnsiZW5hYmxlZCI6dHJ1ZSwicGF5bG9hZCI6IkhUVFAvMS4xW2NybGZdSG9zdDogVmliZXIuY29tW2NybGZdVXNlci1BZ2VudDogW3VhXVtjcmxmXUNvbm5lY3Rpb246IFVwZ3JhZGVbY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1TZWMtV2ViU29ja2V0LVZlcnNpb246IDEzW2NybGZdW2NybGZdIn19fQ==';
    final c = ServerConfig.fromDarkTunnelUri(link);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vless);
    // The bug: transport fell back to TCP because transportNetwork was absent,
    // so the wsPath never reached xray and the backend answered 400.
    expect(c.transport, TransportType.ws, reason: 'wsPath present => WS');
    expect(c.path, '/@your_channel', reason: 'wsPath must map to path');
    expect(c.host, 'sgx.tdz-server.store');
    expect(c.address, 'sgx.tdz-server.store');
    expect(c.port, 490);
    expect(c.uuid, '0bb6cfbd-3a25-46e6-b50a-3b5a25aee3ff');
    expect(c.security, SecurityType.none, reason: 'tls:false');
    expect(c.payload, contains('Upgrade: websocket'));
  });

  test('darktunnel unlocked VMESS (vmessTunnelConfig) imports', () {
    // The vmessTunnelConfig branch used to be missing entirely — unlocked
    // VMESS .dark files imported with an EMPTY address.
    const link =
        'darktunnel://eyJ0eXBlIjoiVk1FU1MiLCJuYW1lIjoiVk0gV1MgTlRMUyIsInZtZXNzVHVubmVsQ29uZmlnIjp7InYycmF5Q29uZmlnIjp7Imhvc3QiOiJ0bmF5ZW00OC56b25lLmlkIiwicG9ydCI6ODAsInV1aWQiOiI5MzYzMGIxNS02N2ZlLTQ3NzctYmVkYy1kNjkyOTI3NjQ2NDkiLCJ0bHMiOmZhbHNlLCJ3c1BhdGgiOiIvd2hhdGV2ZXIvdm1lc3MiLCJ3c0hlYWRlckhvc3QiOiJ5b3V0dWJlLmNvbSJ9fX0';
    final c = ServerConfig.fromDarkTunnelUri(link);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vmess);
    expect(c.transport, TransportType.ws, reason: 'wsPath present => WS');
    expect(c.address, 'tnayem48.zone.id');
    expect(c.port, 80);
    expect(c.uuid, '93630b15-67fe-4777-bedc-d69292764649');
    expect(c.path, '/whatever/vmess');
    expect(c.host, 'youtube.com');
    expect(c.security, SecurityType.none);
  });

  test('darktunnel unlocked TROJAN (trojanTunnelConfig) imports', () {
    const link =
        'darktunnel://eyJ0eXBlIjoiVFJPSkFOIiwibmFtZSI6IlRSIFdTIiwidHJvamFuVHVubmVsQ29uZmlnIjp7InYycmF5Q29uZmlnIjp7Imhvc3QiOiJ0ci5leGFtcGxlLmNvbSIsInBvcnQiOjQ0MywidXVpZCI6InRyLXBhc3N3b3JkLTEyMyIsInRscyI6dHJ1ZSwidHJhbnNwb3J0TmV0d29yayI6IldlYnNvY2tldCIsIndzUGF0aCI6Ii90ciIsIndzSGVhZGVySG9zdCI6InRyLmV4YW1wbGUuY29tIiwic2VydmVyTmFtZUluZGljYXRpb24iOiJ0ci1zbmkuZXhhbXBsZS5jb20ifX19';
    final c = ServerConfig.fromDarkTunnelUri(link);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.trojan);
    expect(c.transport, TransportType.ws);
    expect(c.security, SecurityType.tls);
    expect(c.address, 'tr.example.com');
    expect(c.port, 443);
    expect(c.uuid, 'tr-password-123'); // trojan credential
    expect(c.sni, 'tr-sni.example.com');
    expect(c.path, '/tr');
  });

  test('darktunnel unlocked SSH_DNSTT (sshDnsttTunnelConfig) imports', () {
    const link =
        'darktunnel://eyJ0eXBlIjoiU1NIX0ROU1RUIiwibmFtZSI6IlNsb3dETlMgZnJlZSIsInNzaERuc3R0VHVubmVsQ29uZmlnIjp7InNzaENvbmZpZyI6eyJob3N0Ijoic2xvdy5leGFtcGxlLmNvbSIsInBvcnQiOjIyLCJ1c2VybmFtZSI6InUxIiwicGFzc3dvcmQiOiJwMSJ9LCJpbmplY3RDb25maWciOnsibW9kZSI6IkRJUkVDVCJ9LCJkbnN0dENvbmZpZyI6eyJ1ZHBEbnNIb3N0IjoiOC44LjguOCIsInNlcnZlck5hbWUiOiJkdC5leGFtcGxlLmNvbSIsInB1YmxpY0tleSI6IlBVQktFWTEyMyJ9fX0';
    final c = ServerConfig.fromDarkTunnelUri(link);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.sshDnstt);
    expect(c.address, 'slow.example.com');
    expect(c.port, 22);
    expect(c.sshUser, 'u1');
    expect(c.sshPass, 'p1');
    expect(c.dnsttResolver, '8.8.8.8');
    expect(c.dnsttServer, 'dt.example.com');
    expect(c.dnsttKey, 'PUBKEY123');
  });

  // The two real-world shares from the "all type not support" report:
  // unlocked VLESS+WS with a PROXY-mode injectConfig, and its locked twin
  // (decoy = `{"mux":true}`, real fields inside `encryptedLockedConfig`).
  const kUsrUnlockedB64 =
      'eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoi2KfYs9mK2KfYs9mK2YQg2YjYstmK2YYg2KfZhNi52LHYp9mCIPCfjqciLCJ2bGVzc1R1bm5lbENvbmZpZyI6eyJ2MnJheUNvbmZpZyI6eyJob3N0Ijoia2VzaGFrYW55ZmFjZWJvb2suYmxvZ3Nwb3QuY29tIiwicG9ydCI6NDQzLCJ1dWlkIjoiYWFhYTExMTEtYmJiYi00Y2NjLThkZGQtZWVlZWZmZmYwMDAwIiwic2VydmVyTmFtZUluZGljYXRpb24iOiJrZXNoYWthbnlmYWNlYm9vay5ibG9nc3BvdC5jb20iLCJtdXgiOnRydWUsIndzUGF0aCI6Ii9UZWxlZ3JhbS9AQU0yX0QzL0BBSE1BRDMyMTQiLCJ3c0hlYWRlckhvc3QiOiJhaG1lZC12aXAxLTQ5NzQzNjYwOTA3Ny51cy1jZW50cmFsMS5ydW4uYXBwIn0sImluamVjdENvbmZpZyI6eyJlbmFibGVkIjp0cnVlLCJtb2RlIjoiUFJPWFkiLCJwcm94eUhvc3QiOiIxNTcuMjQwLjkuMzkiLCJwYXlsb2FkIjoiQ09OTkVDVCBbaG9zdF06W3BvcnRdIEhUVFAvMS4xW2NybGZdeC1jb25uZWN0ZWQtdG86IDM0LjE0My43Mi4yW2NybGZdcHJveHktY29ubmVjdGlvbjoga2VlcC1hbGl2ZVtjcmxmXWNvbm5lY3Rpb246IGtlZXAtYWxpdmVbY3JsZl11c2VyLWFnZW50OiBGQkFWLzAuMCBbY3JsZl14LWlvcmctYnNpZDogQEFNMl9EM1tjcmxmXVtjcmxmXSJ9fX0=';
  const kUsrLockedB64 =
      'eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoi2KfYs9mK2KfYs9mK2YQg2YjYstmK2YYg2KfZhNi52LHYp9mCIPCfjqciLCJ2bGVzc1R1bm5lbENvbmZpZyI6eyJ2MnJheUNvbmZpZyI6eyJtdXgiOnRydWV9LCJpbmplY3RDb25maWciOnsiZW5hYmxlZCI6dHJ1ZSwibW9kZSI6IlBST1hZIn19LCJlbmNyeXB0ZWRMb2NrZWRDb25maWciOiJGZkxqR3BNUG45MzIydlQxNjBGcFRiTnE1eEptY1pDdUdneERJcWxyc05WMWNrVmstWnVxQkRqeWVFc0JuN2dsRUk2eFZ6bzFDczYyM2pVdmJla1ZLM0h6dXBQX0xyOU5OMUpvZ3ROODRKSWIydzJQQ1FZZlhJWlI1REo4anJHSGtsMFE0QW43MVdFSUNyd0FwZEZKaXlYcENiMTN2Q1p2d1BSUXlMVEVlemVLdUdYc2pwcGNuQ2lUQ1dYVmpqVU1VTDJza29qbFliclNIRjJ1bkY5M1YzdGdfVUpxM0FTNE9BYlZuaWlmRGtoS21kTEtCYUJUZzJqSm51NlA4Z2VQSW1WeXY0NGxaalJJTXhPZDBxVk1qTFFNdG5KUEg3Y2N4aFZoNTJWTVBPcTZRNlhMVVIwdm9IMzhhMXNXbDVzbXpRVHNlbzBVakdXbllWVGhPNllIVlA1Q1VoZ3hJdEVLOE50aExpWWJHM3VCdUdlZU5rTHg1VERRNU9YUVdwVnQ3cGt2TUk2S1N0YzVLeHVZaTFlRDVlRTJGd1dqM0pkbjh6T0VjRzZKeXZ3SFpBRmIyMzBmQXRVYlVWdzVzTmYwOWxBZXhKYkZPdEh3Q0s5MnNGb1hJU29IOTV0UkdjZHFxM29WNWV1bEUtQjlTdlBNTXd2VTlJa2ZlZFVLaUpEOGpCa19jUVU0M3A2bGlnRUlEcmFzcG9fWUdSQ0h6c2JiWUdFdnVPOGJEU0xpZmJFbEpiZTZ6QVVTNW5LdHpveWtBMGFZTThZeDk3NWlmR2JFQzN2WVl4X1NmN3NYMFRLUUo1SjEtWGdhRUVkaTltc2ZJUWtjeGVwRHhnWm1RZjdiM2FLWlRhbHRLRTFDcHRKSXRyQi1oRVN3M1pVQ2tCRlFzeUgyN3ZlcmFJZTZXNV9jclV6ZGNfQ1I0S3RaY3dXOVo2YTc1MkMwNU5XVGF4OEhCVUlMM2dfcTNrMWJEekhBeGFHMWpDUkdJRC11MXI1dnZZTFNuT01pbGhPcE1XYlozeFFCNEp3cmc2SmxrOG9SaWUtLVJNa1dNWmo2WlZLRmdYajk3XzJTd3BFaXNlTTdjVm8zb0hFSW84VlpWWG0yZnJjNUdfYnFyQlQ4YUN2MGVqZ3ZrdkpHaWViVWtSdG9Ud0lsRHp3bDJ6M1NaU2hsSHpVMjJmNHNPeGxmVkd0S0lhYV9FRzJ2bGpkb1dMbnBLUm1zdHhzVW45b2xTT3ZRd2k4TXM5T1ZFdEdNWFlDUTB1MWY4NkpLeFlBdlhDd3otcy1hMWZxQ2hxTW5qd19jUjVMaEdWNjNDUkFQbWZ0cWJ3QkpEME9sdllaQUZNSnF6LTlrRUhnVXB1cU93QVpYdWNiNmdXbm9uUUVFaGhOYUZNT2hxNVZKbmV6YUVva0FQanVvU1R1blg2YWpYOUs5VUFEODBIZVM3djBYYXZOTVRWV2JSTlY4eXZyLVFNV3ZFU2lDXzlwd3RITWJuSVJkZ3hIWGg2ejVacGZfbzRmM1NqTUtTWC1qOHUzNzdQR1kzWWFrWGtOUDMzSXZnM2dncWRZZGtCYkZCQ0RidnY3M294Y1FGUFRFUFFMXzNGWGFNVy0wbVZxR3lyS1ROTHBrSGkxcEt1eUFCYWl3elh6bHozMHdORHlXYzdKMHVsbzZINy1XLXNaVHFlaWxPNnFGUWhrWXcyZUtrcVdMOUw0WWtkeGZBVi1jMTM0dW14QkFXYkNRTW1YZFV6R3FWVjVBSmFHWmlIaDdneVNQdjA1YWtnMjhDV3h0ZnEwUWJSclF2cS1rY19ZMFh1TFF3bTJDelozMWd2QWgyWlNiLWdVZEc0QXprdEU3bTkxU2htX1Q3b05jY2Vqc1lIMzVjUnFEUTdHUHZIUzZjUEZ3aWR5S21md3VKVmdxbmxpbnFHZzBldjE3dnlteGRKQVNfNVZTU0p3Q1lOM2ZoSFMxcXRnYXczeGVLZEJSOW9ldmhCYnRpSTBnQmVtV2ZFU2xZMUZMMXBRYmdJMkF0TGtCS1RRZS05TFJZeGlzQXJsdi1pbmUtamRFY01PdVhhWE5fekdZMno5bWxuMWN1ZWJfeHdNWFBpVk1lOTJLV1c5WWQ2cGxJS1hOWnRBdG1OTmdIemlZbDFmYlBoM2tValBmR1lfdGlWZDQ1QUFhaXpLdGpUaUdVR3Z5bUtyLXZRcTBTc1B6aUFZY3hDY0wycU1Gc0xGZEY2M1JkN2xRWjFjMFR6ajhZZUhJbEZ4dHF0SWZIVjF5blY5T2lodkJsLUpGUlE4UnluQ1RFTnlZOVY2bWdCbEMwdWRyYTBBTGVjakM3cE95Q0VqOXBMMHk3R3VaQ01ERW1TMi1Pb2t6U2h6OWYwc1gxTmpvOHo2QTRwdWhMejE3UnJQRHQtSjNuTW5EUS1JT2J4Y1JRRXBqbXhIN0ZsUkwxaTNaU2NKMmZtRFlPLTdXVlNSRmsyWE5Cc1NGcWN1ckhPWFNZWVVYM3VkR0Y0OU1Cd01icUV6SU1SejkzcVh3a3lkRi1ZRDlLcVZwSnNfcnUzVEhwU3oyT0lUYWRicHZoWkFYT3hNVHdzVjRURzIxQ2FkdkN0TlEwTGd6TWpMN1dZeVhKd1FvODBJRXM1Q0FYejMyaG1QQ19PYUZyckNMR20wUUNCSG9kczVKdTJzU2F3MEtRUkdvRC1LY3E3LTVKemhjVnozNnZNUFJuZ0RmTm5NR2dtYnkwSHFxRUJ5bjI2X3BlSTV0enBiUHVjc2s1VnhIbUNRd2FHaUJPSHRSZUhqbWdhY25iNDhfbTJIQm1Uako0aEZHelBpb25IM2djTlNPLUprcTl0b2NKcXYtMU5HRm9NZk1CbFpsYUc3Z0swLUZUNEdabGNRRTctUjREQTlkeGctMmtvSnF5S2EzS0k2ZjJlSWIxUXlERzZjQjBqSHF0ZkM2NWdiMHNlTUVaSjJ2VWhBblBhYWNFT1RWbWs3Z3o5V0p0MmRlczVZbk10ckMwX2ZSa19Tc1hIVW9SeUdiaktXdzFqcV8ydG5yaEFDRmpqMVJaRl9WMG1SOWxBRVVyMzhoUXFNU1JoaG9qQnpMN2NrN0FxMWR2dHV6U3B6V1M2Z0VaeVRoa1pTczA1dkhRRkFRdHFiV3B2M2RoUE9XVE1Xc0QzSFpGU093eHk0LVhlTk54ZzhyaEh6cFpZMmFlSEp4NFVEdHVaMXdWeFdtdnIwWDM0VTVKcGZPQVVjLWJqRjFUdHB6WVBUb0EyT1BudEd2a2U0WDRMN1dyeG9PNXFxLVNGSlc2b0tqUkNJVEhRcGN2ejRPS0FWbnB4T1FVVDAzN1A4VjB5aGFRR3RNLXhuem9QbmRtSlBodzdGZFB5Yl9PRzRMYnoyWFlpYkJidGRaQnkxSlllM3dURlVXT3pfYi11dnhQbi1xZWlQWFRLVWFFLTNsU3NvNlB0YXgzQUNVQ0dGMWJiMWdxZWNuSE5jUmZuQWkxZ0x1TDZxWTRVQVMwRi1xZkdtMkFIR1hyRjM3X3ZhYVBNWTg2amw5cVAtcjhlWElHTGcyemFzMGFyQnJZNy14eEdQbEVzZWtUUGlJOVpLVEtvX3VtalpQa0Vrdy1EM3VWZXFIYXRnVThmWkFQSnViOHhEYWxTbVlfNHFxZ3BfRnFEejgxYlVIMHFDUHg0VTNjZ3ZkR2lwZXdIblFOSDRpUm9ZZ0pHcnFwdjVieFdSNjhCQUdvbnJ2M1FPS2h0QXQwS2V0SG5yUFZyREdicVR3MENEZjZ2ZVNFVjJqVEFtT1owNW9tZnRiektRY0pYRFF0YWNYZjJEclFBUFkzOUlpZWRqajFzTTFCVl9uLTVoRUNGc0Rqc194SUZQVFduSU1vWDhoVlRjVzYxTE8wd2pIZXdRV2toNFNpNlhCbU40clJ1SzN3dENQaWx1QVV4TXA3NzU2eDg2eUNuUVpmVmpaclJUajZvV2RnTG1nMW1kWl9nUkJicVVjTG9HNWdnbDc0Zk5KYnpwRGJlbVhwSnVDT3ZlVWFwRjZCMktTYzk1TXJ1NDFRZHlEdDBKakEycUpkOWEyY01uLVFWSlV2ei10bXNPM3Zod04wdHF3WXRibGZ5Yl85aVhZcDNaT3hxZldfMVhUbjhyY2tPM1N5SGxhSmEtTWZDRUdCTno1aUYxRTlJbjZ3V3lnTzFLLUZic05kclVqZTJLTE9IVGExSG5naThPSHFiN05pSVUtT3hwTFhHZnBLcWFhRGJlTE1TOEVoNWlOcFlzVDVRdldvTGlIc2Z5X3ppRFZlUVgwSVU1X3NxdU0yOXhhX0pvclE4endDM2FqTUUxZG5WR1pzczRPZTNoREJHSmtDOXFuOG9ia1ZtdFNsOXBrbWVULXZCWHhNRDVMSlV2TFdlMGh2YUtMUzB2UVFZZ0J4MFZ0U3NvUDVROVNrSm9CLVU3eWdIeVZRU2tTeDUtVzdkam5vMF85dW42YWJqOVk0OGhXdFBjeVBDbExxUWZqazZpbWpTNHByS1BlNVlJUlF5b2plLXZseDFPeHBxLTBTaDBCY0NPRndHT0pUcnc0OUdwNWt3b3NQUENxdFlpYkk2dHJYNTBQMW9tY3VxM2lVXy1hbVNYQUltakNqcUhTUUY5OWhacG9rY3pSR2dTbDRMcFFpUnBqUWhOUGFXb19aV3BmN00xSUxqVy1FWXMzSkFrcUY1ZnR2MnY4Xy04UXJIb3dwd0ZvdURlMlNPTHpZeU9LbmYtbDV6dk9aN08wR1RVOG1VXzltR3JHMVlIczRrM05qSXBXNFJ4dmkxOW5NTkN3eTZ4WW5oYW5KRE9UZE5kcWF6UGsxcWwyc21qMnZUVXpTa0VUTU0zcFF4N0lqYzVwMkl5MnRMdEQzTE1ibGV5UWNMMXRYX1FKb0lpM3lPYWUxcUlCejlzRHRPME9oWXAzNWd6RTdpQmh6ZXhVSnFJLTdVRk4wTWNMYWlESHZGaTA4OVJLczAzeEhlXzJjUmI5X01zcEhJeXRqaGMtSlBrRUNqTF9IUmEtTDRaM0VGLWZLa1NsQk5sTDhHM3FKLWpzXzhkMGIyMWJUaS1qOHB2OUp5YkxOWlJwenZ2S1JORk93RUVLemVkMGtKLWRyTzB4Y1E0OU1GeXNjb0F1aWtzbjhZYTdxaGNiQU9raVFlbktsck16dWE0aGNXaFhkeEwyQWZ6dmc1dmpTcDFhWWF0bFNVMFNxcmU2UUt4VW5LN3Q3Zmt5UHZFM29iNkVIdEJVOVcwZUF3ZkxhTnZoSF9qNGJwTjRyTjZWT2xob1Q5dEN0emI2TFdsMDBTVV9wNWlQbXAwZ1ZKNjRQQnBHUGJsS0xyWUR6VnJJVkwwNW1uYjQzamlwb1c0YnRfazNqem5hQ0ktcHlad0I4NkgwMDBOVUM0UU00RW1SN1BucVlYMzhZVmpMamlVNGV5RllfbTFScHlBQ0JYLW1PX0JGT2RzblJJVTZoY2h4dkVrRHY3TmhFRjdITHdnX2pxbmVjVVhTUkZuemYwTDFZMDhHamtZWFY1ZnZiTTRlRXZPSnZjTWdXa2QyTEM1dDhPbnJGX1hHVEdJY2ZQSXpzY2RzMkE2d1dBcnoweElXMTNpaTdQVDBneVhnV0ctWHhNMTFsRERuZmI5ZDJSU1dxWlo2ZERsaVJjbVpxcUNBZV9jZWtYb01JVy01dWtqX2xhbk1wMlRXU21PdGV5a2l1MVlJejNMdjNOdWlneXBiZms0OWVONXRtampNUF84WXJuVGUybkZZcmthNVp1ek9GalBuOEc3TWRpc195LV9HcFVHMUJmcjBXYTM2Z0NlbEg4OWFLNWwtckJjWlpkZ1V1OXBSSHBTTkp3UUoyM2J1X1JTSmstMTRuTlJ5R19CYXphMFRYVU9WMFQweGJrTUI4S3E1ejFSdV95d3VDc251cW9kUjdURGQ3X18yVWhMeWNzVVZ4ZUZPSEl2ckZGX2VpeVBCeXhMMDdRdUMxWTl1cm5pcUNESkJrM1ZuZEZhcGVPeTJTdTZYQ0s5S1RSOUVKMGlUZlVCWDEwTE8yLWhnVEtOeTRTbjE5d1VqZzI4Y3pYM0M0aHZnaW8zVGdMRHJ6SDhBVzNSODVqM1pXWVZWTjhfQmxhV0oyM3Zsbnkwd1p0RVNDVzlsX0pSZjdVTjRqc0xDRWE1SjV2cXFQREtTTV9WeTJlZUs4RVIwWkdUTGRyeEkxUEdrUEpjN1NucE9fd0Q2N25WalZUVDN6ZmdpMXcxbVZaR3hHcjdHNmRuVEJ1bWFfQzhmbEJBRERiQlcwcXR1R0ltT3lSY0h4RzdPOU5wcG1ZM29pckZ1aF9sUEpJUzRfUTF0dHRTZzZHd2cwMzNSWWVrbWZQeVZ3bWkyTU9OVmtTTHVxaTRVdWk4Nk9abC1Fc1lQWXlEVHI5M0Rsd1lQeGhkTUdza3ZnTVk1U1lJMmRQblhIX1A1aHAyZDk5NktWVTZRdUlZWXhSX04zWmxhNTJhWXNtQ3VuZEl0QzByeVFFOEJoNkpkOU84UUtrY3NTYXB1cHhaRmprSngxaGhwQVhWdXp3Z2cycXdiTHNPS3k1WTQ5V0t6eGFVX3k2SEhpTXhSVUdFTmE0aDlYTU5JRUNsWkU1eUlHUEU0MmM5Q25BOFdoNnhLYVIyZG81aXlmSGljdllET2k2djdOSWdmUkVWcWVxNzdJMUNEdGF5MHRMU1lwRDRWajVLM19KeHc4c1dyMzk5aFZ0Xy1MTFU4bl9hNzhEYWFUaGpxRXBBb25ocEpLZzdjbUxvaHVMYmlfeVlKRzVGa1FCSS1TNEoxenhSMXNxQms1bVJIX3ByRE9wTFB1WTBYX2I1aWVsdE42SnRmLWIwdThQUEdWNk5FZktyalhKUVlrSjVsMndWWUYxaF9MRkRBVmFvX3FSSl80ZzJ1OWUxSEcyVVJ5NUtfTWtZRkNfNkdDZGlmU3JoRi0xYm1lYVV0MW1CTHA1RXpGbGFTVWtqby1kNEZKZW1GTzhLWkZhQnZjZ1MwMTRRTG5CNUpqYnVuVDYwTUlCNUNfbnN3U24wUWtJQ2dNYU9nblFmbkZ5SFd3UTBfS0t4NlFZRGJlZGVhSWltcXd6Rzk4Z0tlWXRMLUgwaWVESC13eGVkcHFCczhKWnowOExCTjlJTUVVRk9IUDQ5bEowYTgxRTdIaVFqSkJ1OHpwWlE3Z2ZvRjVueGNwdmRvTUdRS08tRWJzRDFVYjVVX3BhZW9mZ1JHeWVDaEZqemRRbWU2RE5qMU4yaDlHVFNPYndqWGFzN2hFV1dZdVY3NW1VeHd5Y0h2TU9qUTVnbDl6WUxXQmNqSEtrWlZRMEJFLWkzd3JvbkdIWGRVR0h6YW4tbzlDODR0VTZUZHNOaUgxbDI2ZmxBM1BmYVRCVDFzUDV3cEEyY21scEtMUjkyME9QcDhfelFDbW9wTkpuV0ZTeWlHRV82RWhhZFNpS2g4alpGNERuUk0tSlFDRFJJRzFFeURvNXhWc0F1bnlhc3gtRzZ3VVcwSWxkUk1HSFhBLURFZEJzWUcxMFdsZW95U2FFZWZpRGx4LW5NNkk0aThraG44Q3EzTEJ6N1dfbU55aWVzcXpaem1kTU1FSXpxRmV2ODBZUEhCSVRUVXRLdU9iSG90V0M0VzdWcVJxNFowWWxzOVUwQXFKam9qdkxyRHBDQWJhcU1GS20zVDRWMGpUMEcydVNMYXVJcldTNktJMzU5MzZvVmxFYjF6U3hJUzdySldwRmtleDVDWUFmcVc3Qk1uWW4wcUZiNHJab09BOGllN2JfcEttX3dPQllVOFU1Tzg4eXNrUFB4d3FQeGFTN1dFSmUtYS1kX01ITkE2TWo2UmlpdklOVkhnZ2Z3QTBfVjFqNm9nY1kyR09kZ2lMSC03UmNMNUt4UDZQempvN3lzTWxaYzhzQndyNW8tYkhoajFZMlJlNV82a0czNjh4SlpjdmpiNmhxZ21haVkzZExVYnZaRkg2c0RlVlJjbjR0cURSSW1BSllMdEdSU1VmWGNXZnFCY3RlbnRwR0lWdHpadmNYRGQweHM0WW43b0tfZl96WEpFTmdVLVRpdXdxOWdJUk1pdFU3TjlzOGFpSHV2a2NJMXdwMXR5Nm9Wd3c1Q2FIM09PMUV5LU9LeVh3MGFPRV9jSkprMHBMdEtDNGZlTFhMZTR1cWJCdENKb1pzY0xGY2RxaGJpam5XdUZsMVlwLVlaWWJZWG55X3NfdVM2U1NpNzZVWjIwYzlGd1RCR1RDRjBUWHpmUVh5SERGMWhNbXJKTnlFZnFXQnBoZG9sR09STTNrbk02WU9Gb1VLUlcyblBxVURRbXRuVW5nMTN6dnV3YUVtMlJnUnQtSVpvZm0xeHl3TTF5QWpMdGlvYzZpbXQxRzQtZC1JWGRXNWN3TmFFSmVFYlZFcW9vMFlwMGE4bTZyVzR5d3ZhZnNpSmtMYzZGM2lnR0JOOTR2U3RLYnpsT2gtbU9DVk5mYngzakt5ZnRQV2JDTTZyQl9JNklJQ1pXZVVSRVNxQU9NOU5ONHZPenBrZ2tDVlp0TzBvblJyUVROOUdFamswNDRUQndhUm0yREk0Tm1BYmZnYVFYVDE5aHBOS0EzYlN5YnNEdTNEcWdIVjJaSGoxczhsNDl2NnlvWmEzaFFCYnlSZTdPNmFuaUJyZ2xaY2U1ams5STVXOFJzb2lzX3VfRVZDRnJNaER2QzZ3QmJwdjdJUFMxTTloeUJKLUdHVnp5OFFxYk9ZZG9EYUFLUXFzMmthU213QXRTY3hDRmFZanoxOXZiTnVFZl9GbDdBY3poMWs2b0JqMnhMUWFORWRMb3ExYU5rdW55RVhhd1BaamZSWWZUcTZYYVRpdFluODNzZDNzSnNENTZmOFM4NzljakxBRDZQek1ZYkpyNEdZVTM0NzJWdWg3TUl3RHVvdi01cDRFLUdYLTEzc2gydmZiUDVtYTBUU1RHOHdvRjg0dXlSQkE0SzlVcnV2RnBSSzZZWjkxZU5UVWJrQ3MyTnNsN081eHNQTmpWYjZ4RjRIMUE2clROTEdTUTF2VFJfNlFtdkxQcGFBT19xcktwc2MtRlFJbDlSd1FycUl4a1Y1cXNRU3RLYUk3azZCSjVpZVNGbS1DcFNYS0xJMGRnYUVPTHhjWjNfcGhHMTJXOUMyLWxFUkpBbGtMUkEtak5ESFFHSTdsc0oxa2o5d2RVSW16UU93dDlZdm9JZGptdXRsQlZ2c0dvT20ybjEtMDU0RTN1cUo5ZmwyZGU0X1BNWnJUeGwwUE4xRnFiRzdBZmpBVEgwYkN5c25jYWNmMU1kd3FnbGVHam9JanAtZzRpMFdlOGp3NlNFTkNxYkNuTnJlb0U2LU5EVFdHUUJBNWp5eGlyOUJqTTF4Mzg1b21CeGtGRDRBLWJXeks4dFFDbTV6dUVObHdLdExPUGd2bml2NUNSWmlwRU45YUl3S0dFb1NNTmVjU2p1ZkhDZXJwNzAxVUNMQ2JtY3hrOVlrZDhTSTlnVWs2U3IwMGZ6WjlvakFDOFZ6b1JJYmQwbm56US1kYmFleW1ZRVJmRFNIVlVWMV9nejlMSUs3c3dYSWJuVmZHT1FWckxiMHVzeFkwNlNHOWRhcVFqUy00aUM5MGV3SlpIa01XTFQxS1BXRVhqUllMNm1kN0JiS1piWVhxdEVMdlRTOUJkaFp3UG9rUmw0NGFhT1RRRm9JMl9GbWFPR2xYaENRT05yMmNjTmhjb2toamx6ZHVocW9QVlhIMGpuZG9PSi1SQnNnYmVHWnA3Z2pkNUcwaW02d3ZRQ1RnMnlrYkVub1AtVDJBQnpSR2RFaGt2ZEx5cldueVZjSC1XaXFnSmNZdmk0X3NZNGRNbXZaeVZTUjNOQ1lYWjFSODdOMGJXQVpmOUhtWmpRa29kcGtIRFpESVBjWDM1eHdOV3diT1pMRmNadGtGZm1IN3BncGtROVpmdGZPSDhuWURCZlNuQmFhY3ZaRmluTk05ZUlsTWk2R1NjZkhCY0l2eGVUWHIwY2hQTXA1WFVXTXFiSWx4eThhSFlFVG5WVVhxRlI3WmtyNlV1UW56ei1tbWMzd3BkTTBZSjJXaC03TFlYS1E2OTYyT3N5aThLeXk5WENvejZOaXVtUTE2U203enpBN0JoTkhvamhuRUF5akZHUWh5ekRaUXVVN1JpVzFKVUJrN2NVc3RqOXBmVWZvLTItXzRWR2VoZi1pQzNDbmFvVXlCRWx0TkwxQV9hNTVwS1F3MTVYMHpaMWxZWWE2cTA1bGRacDZJVC1yajE2RjhkZDNwekNSV2xWTlBySlBpNXU5SVBOeWNta2NXTENUbDlCU2pqcklMX3hfdVdiM0lDaU1nWHkydENIRTdTQzNmZkRUSUhjQlRPbTZld0pJbWJ0djBRWFYwcms5N2pjelU1V29TOWNzc0pNUDFsYWctYWUxQ0RQZm1NVjhDRUFYai1SX25vLUcxSnBicmZSdU9FVFdHZm54TTBWLUdaWldXUEFSclI1by1WSmZjQnVWbUh5MUpuSUtVY0hYX29OcENYUVJYdklUN3J0UEw0LW1oVjE5QXNGMkpNOEl2dHJBbUhxNmFUUkdjVjlMdk1WX1NVMVVvMXRTUDZrUFROeENBMlNDMkgwVFVVOWd2dlFoWk9WWGZJWHNhSy1ZNTNoSG94OE1CajROcVhvME5jWl85TGMyVG5zU2FFUHRMTER5bWRXRm1aSVdyZkRHdVRXRE9YNGNNVl9xcm0tTThTendWMVhjS2hRd19pb2Fac0VYWjdhSjNaZ195RmVnNU5YbkZCcm4wWUJXcktRR200akhydlNxRG56VTZ2cTJmNm9HbEc2Z0RxQ3BaSUFRdTZka0VNQnBmYVAzOVdpVWtKenpVTGFHbTRXY1VlOTN1eHBQNHNjQmVKQk5TTzNoSmpvM081SnZvX25yUTdWOU9iYXB5MVB6SnJEWHhWdExHVUFTaU45V3hJODIzUk8wbVVocE1KaE5MNmd3WVd5T09SUHRBeUpVZGlEcktvRjJDaXBrTkNxMWpkQ280SUhmVTFoTHhhUnBVYkVmQUprNmZqMzI1VGs3RU9hM0RsSnUzX2tyU21pZlVyS201NWFyVEFrUk41a3BsZWlMOXludnpSaF9fWXlRemR5XzhTRC1OeGJGeE9tTlo1UUpGeXRDcUVmek5CVDNHMnpzY3d5RUE4aXdmdGd2LXdoWGNoVFh6OHZoR0JOSlFscnVZZTFXU3dlbTg4WEdKbjlkQUo0cnBDMTVKQVZiMGtKYVh2Yy12ZWZtZTJrbm9TbFdIOFpsNjFtTW81ZWlIZ2lNM2dIZmpXeFhHUU5GaE1FaEtxdGotdjdYYlRNNGh0S1dTb0pIeTdEeDB0NUVmdzVKY1pRSkg3aHZ1Y2d5bk9sSnU5TWtCQkpBLU5RcGZYSDBJN3puMERqSWJKXy1hU2xaNm1uOW5iblZHaHQ5bWJRVkV4S2hybHBXbElMZFZVWVpQVmtNQzBoVmZlNmdONjhFMXdLbHlDUEF4TWJVcGZoVlpXVV80bWRJdWlTOGpLR2lZVFF2UmJOdmtucUZseHpZSWI4M094bk9EN3ROelJPNjBoV1F1cW1ZM2tTZ1Z0M1UwMVc1VlphMkdDdGVjSFZfTGlUeEpRRlAxMVE4QVUxLWNfZ3M2V0hKLTVwdTRKelI4Z0N6Rm9yX0VMNVNjaWU0T3BLWjhYeFhUNXRtZEhMS0dmdGtlVklJV21ZWGFyX1N5UkxsemRaamNZeU5zOVNFWE43Z1lod1ZsT1oyQzhmU2JwdXBreFpuZXBPNHNLT05EMUJEeDh2QlVyNmpWOTVESTgxVzVoZ1YwS1l1UVJnekE3Y0ZNSE1xZjdvRngtZHlNSzJELU9NN2RtUjNkM3JXaFJ6VDhvS0RZS0tydnZ2cnBjZ0tpaUNkbUNwMGp0SXhlSTBCME9WRGk4UURTRDY5d3hBTmIxc3ZvakVmbS0tODI1ZWE4MV90U1M2RkRlY3hUOFFiSGxOX3lZaDVUMDdkMTZYazZhbTVFNUNkTGtVMDRSTVFSMUZ6aW5pY3Y5UnJ2Rm1HSUZWdlJ1eXltRWZIc1gyaDZLSVREWFVxS3V3M2tjVjhqUUktbUJwU1V6d1p2YzVVcUNqNXZDY21YbmJqLUJ3ZlVIMEpVWll1dnVGZHoxSHdXdWw4RnlqOGFMYlpELV8zQkkyVW90ZlptVDQwSnZIdU5hXzZKTGRZVWFOU3RnYTdJTjNqUXBDWGJOdnU3OFdPemR0SE8tQ1NhTkY0RVJTd2FFNTNGX0JKaDBpd3lFY3NneFZ1aHFJRXNia0hRUE9jS2ZWbkpNa2lUVk1pVTA0NGkxREpVV1ZvRlFiU09TSXQ1OURJc2Y5bDdqZHdVVWtWZ0FMUkxIekpXQVhtcjhYNHdTM01uaTVxU1dCREtiWTRiTGtuUWw3Z0pFd2N1Rm1xQTk3NlR4b0pYaDkwWjE2a2V5WWhVV2U4VmhfVUk4TEFEVUEwaHp4cGo5Um1mbGlzMXN2Yzl3dlpRMnZnUldqTWtUTXJGckxod0dOUV84M3FvdklyOWpkQVZ0OGt0cVdiVFd2c2lDTjE5eVpFb3Vjc3RrNDd6cjJhRjlYTXcyNEdKcldfVWgybmRIT3lKRm9naDkyUVBTSW1yQnVESE0tRTVUS3ZzdVJ3N0RaT0xvclpRSzZGOU5CVkk5c0VXVTJObDlhSXJwQ2kwVDBMTHFLb001RnNyaW1ZdkQxbDlFZnhXVmxQcXVxV3hhTGQzWmJ5LWxuNXVtWWdLSkFKWU1jVHVVeGtwLTlabC1GMWNGaDRncDh6ckNhQ2J5N2dCTnJRQlFHU0pGR0lhVnIwUF9jQlVSZVhFOWdiQXRTVTRBRkFheW9WalJQdmtaTjUwMTdYYUhQTXVyWm1ZN3ZOXzBFeXYyRl9nVzlkM3NiUm9uU1l1M09OSDkyZk82TWEzc25JaU56aUNSVTZDUzVBS21yRlJYemFhZzl5RXN0WTJHdkE3U0xoekhwakJZalNVSElBcDVsYmZsSmJSeVoxSTRTRTRoRmNpTkYyV0Y4VXJKU3ZzVWlsVHIxaGRiWjBialJjdklZZjZnQjhOLUpTYkxYVG5Kei1JajA5SXRfSXBHejFLa0RRWGluRXNFQmcwNV9OX05hcUc2VFJjVGNLcC1MNUZVemZwWlZ2RzFSZmVtVWlsYWJ0V19WcTIxWWVUdl90UHpCZUVKS2U4RmRwQl9Vc3JTNTFBM3dSWDhjTkExSThNejlEOUtQNUdUOG1xZ090WFkxR085S21UUnRkSXFRR21tUk1xejU0bVNteVg2Rm5OUnp4c2ZScDFtNDRGUzlrUmFTT3VUV2ZJNDZoNjROX2ZVUW53ZFhxRHB6UVhPc3dMSGt5ZS01S1E4MGREb1Ntc0FCTlkxRm0zQmdBVVYzbTEtelgxU2dUZGZhZDFvVEFWUEs2blJqa2NKbWxyTHJLOF9aU21jcDJFbUE5RnBLY25fUlhiNWprNzRuMGhTSko1QUxnTmNUVldKVlJnalFwcUw0OWpXQ0hSNGlaQVN2TGlwS0lTd2g3X1NpQXBKdldxRHkwYVdHc1hySUh3SnVtdW40T2NXVW41TExiV0xTb19CNWJ6M3pyckd6MmxWWFF2OFBHZEhCTTRPSU82ZVZHV1ZzcXFjdGhMdmF4OThqTVY3THhyMFRuVlE5MVdSeTY4d2JIcTh1QlJUN3J5VEgzbmUwOU1LZ0VpM3ZERzdTbFBYY3dkeTM3R3FtTTNZSzgtVUlmUkhXVUt5UlM2c0lhaFFVYzFoamlSalI4SVBSMWRPTjFJcS1lRmpQSEdsZHM3Y1JSNzFlX01OSTRDYlZkUjdVR3BjSTdEMUJMOFpyRDhVbHhjSmtfeTl2Vi1xVDBSWDVuOC1JOVR3d2ZnOURGUzlxY0poTEtkdXNCNVNHSnVtWWkwLUdlbzRObHBXRm5WZWtSVllPd3lDS2FWNFF6dlNhajFtRFdnSTB5SlMwU1lxY2pNNlJrS0hvZFk2b0MxTmw4UUxUYUZFdGpxaUdBYWJHSi1sVUF3ZFotZF9FSlhyV29vOUFfbE9NX3E4Umh4SmtYbkEtaUxXdXo4VmFDV1RiREdZbEZtQmpoTFFXa0JfRkdRR1RlcmY5eXI0ZmlsSWxOd2NwcHljcHFrMHdmencwSk1TY2wyb21Dbld3QkNqY2VicTdHNXFQMm5EVl96TVNPRWJIT183WFhsaHhXekx3Y3M0YTVoVEt0T3JXcnhqV3F6MjNQQjMtd0toMTF5dnpFTG9JTm1pWC0wY0R4dGt0Ml9udlFZd2JRcmQ3ODdSY3VMY1ZXN2V4WjBVZW1qOUVfTGNjR1dmZkpNRko3cDN1QkVOMFktRVA2emNpd3RfOURDX1prRzlyQVdIakZvMjNRaUFScm1FdnpGX1lZRnVnd0hQdkx5RHI1Sll0Ty1wZnhzRkt2TTlGR1NhU05kS2o5UFNBUldaZENwX1FzeHRfRkpRTVNEZjkwY1M5Q2dYRVU4dDRjckpibWIybWFiNGVnUURQQUh4NkYwLWt6djV6aWdqRnBKZFYweXQyT1hEM3REeWQxaUJJV2RDM2ZLV3piSUQwNFc2ZEFzUjA5ckpJMW1HOU5QTlZzSjdRMDNaamlnSXBsSkoifQ==';

  test('darktunnel unlocked VLESS ws PROXY keeps bug-host front', () {
    final c = ServerConfig.fromDarkTunnelUri('darktunnel://$kUsrUnlockedB64');
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vless);
    expect(c.transport, TransportType.ws);
    expect(c.security, SecurityType.tls);
    expect(c.address, 'keshakanyfacebook.blogspot.com');
    expect(c.path, '/Telegram/@AM2_D3/@AHMAD3214');
    expect(c.injectHost, '157.240.9.39');
    expect(c.injectMode, InjectMode.proxy);
    expect(c.payload, contains('x-iorg-bsid'));
    expect(c.v2rayInjectActive, isTrue);
  });

  test('darktunnel share with trailing comma (bulk paste) still imports', () {
    final c = ServerConfig.fromDarkTunnelUri('darktunnel://$kUsrUnlockedB64,');
    expect(c, isNotNull,
        reason: 'trailing comma killed EVERY darktunnel import');
    expect(c!.injectHost, '157.240.9.39');
    final c2 =
        ServerConfig.fromDarkTunnelUri('darktunnel://$kUsrUnlockedB64, ');
    expect(c2, isNotNull);
    final c3 =
        ServerConfig.fromDarkTunnelUri('darktunnel://$kUsrUnlockedB64,extra');
    expect(c3, isNotNull);
  });

  test('darktunnel locked VLESS decrypts AND keeps its inject front', () {
    final lock = DarkTunnelCodec.decode('darktunnel://$kUsrLockedB64');
    expect(lock, isNotNull);
    expect(lock!.tunnelType, 'VLESS');
    expect(lock.passwordRequired, isFalse);

    final c = ServerConfig.fromDarkTunnelUri('darktunnel://$kUsrLockedB64');
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vless);
    expect(c.transport, TransportType.ws);
    expect(c.address, 'keshakanyfacebook.blogspot.com');
    expect(c.port, 443);
    expect(c.uuid, 'aaaa1111-bbbb-4ccc-8ddd-eeeeffff0000');
    expect(c.path, '/Telegram/@AM2_D3/@AHMAD3214');
    expect(c.sni, 'keshakanyfacebook.blogspot.com');
    // The locked branch used to drop the whole InjectConfig.
    expect(c.injectHost, '157.240.9.39');
    expect(c.injectMode, InjectMode.proxy);
    expect(c.payload, contains('CONNECT [host]:[port]'));
    expect(c.v2rayInjectActive, isTrue);
  });

  test('darktunnel locked share with trailing comma still decrypts', () {
    final c = ServerConfig.fromDarkTunnelUri('darktunnel://$kUsrLockedB64,');
    expect(c, isNotNull);
    expect(c!.injectHost, '157.240.9.39');
  });

  test('darktunnel renamed tunnel key still imports (vlessAunnelConfig)', () {
    // A real share from a seller batch. The key is `vlessAunnelConfig` — one
    // letter swapped out of "vlessTunnelConfig". The old exact-name lookup
    // returned null, so EVERY field was dropped and the config imported blank
    // (no address, no uuid) and could never connect. The user's symptom.
    const link =
        'darktunnel://eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoidmxlc3MteXByMnMyYm1nMCIsInZsZXNzQXVubmVsQ29uZmlnIjp7InYycmF5Q29uZmlnIjp7Imhvc3QiOiJiZGF1Z3VzdC5wcm9tdGdlbi5jb20iLCJwb3J0Ijo1ODIzOCwidXVpZCI6IjA1Zjk0ZWQ4LWI0NDktNDRlYi05MTk3LTdmZjc4MmE2MGVlZSIsInNlcnZlck5hbWVJbmRpY2F0aW9uIjoiRmFjZWJvb2suY29tIiwid3NQYXRoIjoiLyIsIndzSGVhZGVySG9zdCI6IkZhY2Vib29rLmNvbSJ9fX0=';
    final c = ServerConfig.fromDarkTunnelUri(link);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vless);
    expect(c.transport, TransportType.ws, reason: 'wsPath present => WS');
    expect(c.address, 'bdaugust.promtgen.com');
    expect(c.port, 58238);
    expect(c.uuid, '05f94ed8-b449-44eb-9197-7ff782a60eee');
    // No `tls` key, but an SNI present means TLS-wrapped WS.
    expect(c.security, SecurityType.tls);
    expect(c.sni, 'Facebook.com');
    expect(c.host, 'Facebook.com');
    expect(c.path, '/');
  });

  test('tunnel section lookup is structural, not key-name based', () {
    // Same payload under three different key spellings must import
    // identically — the seller mutates the name per batch.
    const inner =
        '{"type":"VLESS","name":"x","KTunnelConfig":{"v2rayConfig":{"host":"h.example.com","port":8443,"uuid":"u-1","wsPath":"/w"}}}';
    for (final key in ['vlessTunnelConfig', 'vlessAunnelConfig', 'zzzTunnel']) {
      final json = inner.replaceAll('KTunnelConfig', key);
      final b64 = base64Encode(utf8.encode(json));
      final c = ServerConfig.fromDarkTunnelUri('darktunnel://$b64');
      expect(c, isNotNull, reason: key);
      expect(c!.address, 'h.example.com', reason: key);
      expect(c.port, 8443, reason: key);
      expect(c.path, '/w', reason: key);
    }
  });

  test('DarkTunnelCodec.extractUris splits comma-joined bulk shares', () {
    const bulk = 'darktunnel://$kUsrUnlockedB64,';
    expect(DarkTunnelCodec.extractUris(bulk).length, 1);
    const two = 'darktunnel://$kUsrUnlockedB64,darktunnel://$kUsrLockedB64';
    final uris = DarkTunnelCodec.extractUris(two);
    expect(uris.length, 2);
    expect(ServerConfig.fromDarkTunnelUri(uris[1]), isNotNull);
    // Newline-separated + surrounding junk still yields every link.
    expect(
        DarkTunnelCodec.extractUris('my configs:\ndarktunnel://$kUsrUnlockedB64\ndarktunnel://$kUsrLockedB64 🎧')
            .length,
        2);
  });
}
