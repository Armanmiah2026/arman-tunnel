import 'package:flutter/material.dart';

import '../theme/sensei_theme.dart';
import '../widgets/ui/sensei_controls.dart';

/// Offline help assistant.
///
/// Keyword-matched FAQ, not an LLM: the answers are written against this app's
/// actual behaviour (three-place flag wiring, SSH UDP limits, blank-payload
/// semantics), which a generic model would get wrong.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen>
    with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final AnimationController _dots;

  final List<_Msg> _messages = [
    _Msg(
      'Ask me about connecting, importing configs, payloads, SNI, split tunnel, '
      'route rules, hotspot sharing, DNS, MTU or errors.',
      false,
    ),
  ];
  bool _typing = false;

  /// Tap-to-ask starters, so the first interaction needs no typing.
  static const _starters = [
    'How do I connect?',
    'Import a config',
    'Payload & SNI',
    'Split tunnel',
    'Share over hotspot',
    'It says error',
  ];

  @override
  void initState() {
    super.initState();
    _dots = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _dots.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? preset]) {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(_Msg(text, true));
      _input.clear();
      _typing = true;
    });
    _toBottom();

    Future.delayed(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      setState(() {
        _typing = false;
        _messages.add(_Msg(_answer(text), false));
      });
      _toBottom();
    });
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: SenseiTokens.medium,
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _answer(String question) {
    final q = question.toLowerCase();

    bool has(List<String> keys) => keys.any(q.contains);

    if (has(['connect', 'start', 'turn on'])) {
      return 'Pick a tunnel on the dashboard card, then tap the big dial. '
          '"Connected" only appears after a real round-trip through the local '
          'SOCKS port, so it is a genuine check, not a guess.';
    }
    if (has(['import', 'add config', 'paste', 'link'])) {
      return 'Configs tab → + . Paste a armantunnel://, vless://, vmess://, trojan:// or '
          'ss:// link, a full .ovpn profile, a locked config or raw JSON. '
          'The Manual tab exposes every field if you prefer typing it.';
    }
    if (has(['payload', 'inject'])) {
      return 'Payload is an HTTP request sent before the real handshake. Leave it '
          'blank and the SNI modes act as a plain TLS wrapper — nothing is '
          'injected. Only the PROXY modes get a default CONNECT. "Enhanced" '
          'splits the payload across packets to dodge inline DPI.';
    }
    if (has(['sni', 'bug host'])) {
      return 'Settings → Engine → Custom SNI overrides the tunnel\'s own SNI at '
          'connect time, so one server works with several bug hosts. It is '
          'resolved on the Dart side into the xray config, so it does not apply '
          'to SSH or OpenVPN.';
    }
    if (has(['split', 'per app', 'bypass app'])) {
      return 'Drawer → Split Tunnel. "Exclude" keeps the listed apps off the '
          'tunnel; "Only these" tunnels nothing but the listed apps. Either mode '
          'needs at least one app or the connection is refused.';
    }
    if (has(['route', 'block domain', 'direct', 'geosite'])) {
      return 'Drawer → Route Rules. Add a domain, geosite:, IP/CIDR or geoip: '
          'entry as Direct (around the tunnel) or Block (dropped). Rules land in '
          'the xray config, so SSH and OpenVPN ignore them.';
    }
    if (has(['hotspot', 'share', 'tether'])) {
      return 'Drawer → Hotspot Share. Connect first, enable the phone hotspot, '
          'then point each client\'s Wi-Fi proxy at your phone IP on port 10808 '
          '(SOCKS5). Port 10809 (HTTP) works for V2Ray and SSH protocols — '
          'OpenVPN has no local HTTP proxy.';
    }
    if (has(['udp', 'quic', 'game', 'call'])) {
      return 'SSH tunnels are TCP-only (SOCKS CONNECT), so QUIC and most game/VoIP '
          'UDP cannot cross them. Port-53 DNS is re-framed to DNS-over-TCP '
          'automatically. Use an xray protocol if you need real UDP.';
    }
    if (has(['ovpn', 'openvpn'])) {
      return 'Pick OpenVPN in the manual form and load the .ovpn file, or just '
          'paste the profile into the import box — it is detected automatically. '
          'Profiles with a bare auth-user-pass line need a username/password.';
    }
    if (has(['dnstt', 'slowdns', 'slow dns'])) {
      return 'SSH + DNSTT carries the tunnel inside DNS queries. You need the '
          'nameserver, the server public key and a resolver (host:port). It is '
          'slow by nature — use it where nothing else passes.';
    }
    if (has(['locked', 'lock'])) {
      return 'A lock is set remotely by the admin and arrives with the config '
          'bundle. Settings → Admin Status shows the message. Connections stay '
          'blocked until it is lifted.';
    }
    if (has(['update', 'version'])) {
      return 'When Force Update is on, Settings → Admin Status → Update Required '
          'has the download link. The app refuses to connect until you are on the '
          'published version.';
    }
    if (has(['battery', 'wakelock', 'background', 'killed'])) {
      return 'Enable Wake Lock in Settings and allow battery-optimization '
          'exemption from the drawer. Aggressive OEM ROMs kill the VPN service '
          'in the background otherwise.';
    }
    if (has(['mtu'])) {
      return 'Settings → Engine → MTU. Try 1400, then 1280, if pages hang or '
          'large downloads stall on mobile data — that is packet fragmentation.';
    }
    if (has(['dns'])) {
      return 'Settings → Engine → DNS sets the resolvers used inside the tunnel. '
          'On SSH, port-53 UDP is redirected to a local DNS-over-TCP gateway '
          'because SSH cannot carry UDP.';
    }
    if (has(['error', 'fail', 'not work', 'cannot', "won't"])) {
      return 'Open the Logs tab — the engine explains itself there. Usual causes: '
          'server offline, wrong UUID/password, an SNI the CDN rejects, or an '
          'inject mode that does not match the server. Diagnostics shows the live '
          'transport state.';
    }
    if (has(['theme', 'dark', 'light', 'color'])) {
      return 'Theme lives at the bottom of the drawer and in Settings → '
          'Appearance: Dark, Light or follow the system.';
    }
    if (has(['speed', 'slow', 'ping', 'latency'])) {
      return 'Drawer → Speed Test measures real latency through the tunnel over '
          'several probes and reports jitter. Throughput is deliberately not '
          'faked — no bulk transfer is performed.';
    }
    return 'I can help with connecting, importing configs, payload/SNI/inject '
        'modes, split tunnel, route rules, hotspot sharing, UDP limits, OpenVPN, '
        'DNSTT, MTU/DNS, locks, updates and reading errors. Try one of the chips '
        'above.';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: const Text('Help Center'),
        actions: [
          IconButton(
            tooltip: 'Reset chat',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() {
              _messages
                ..clear()
                ..add(_Msg(
                  'Ask me anything about Arman Tunnel.',
                  false,
                ));
            }),
          ),
          const SizedBox(width: SenseiTokens.gapXs),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.pageGradient,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: SenseiTokens.maxContentWidth,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(
                        SenseiTokens.pageInset,
                        SenseiTokens.gapMd,
                        SenseiTokens.pageInset,
                        SenseiTokens.gapSm,
                      ),
                      itemCount: _messages.length + (_typing ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == _messages.length) return _TypingBubble(_dots);
                        return _Bubble(msg: _messages[i]);
                      },
                    ),
                  ),
                  if (_messages.length <= 2)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SenseiTokens.pageInset,
                        vertical: SenseiTokens.gapSm,
                      ),
                      child: Wrap(
                        spacing: SenseiTokens.gapSm,
                        runSpacing: SenseiTokens.gapSm,
                        children: _starters
                            .map((s) => GestureDetector(
                                  onTap: () => _send(s),
                                  child: SenseiBadge(label: s),
                                ))
                            .toList(),
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(
                      SenseiTokens.pageInset,
                      SenseiTokens.gapSm,
                      SenseiTokens.pageInset,
                      SenseiTokens.gapMd,
                    ),
                    decoration: BoxDecoration(
                      color: t.surface,
                      border: Border(top: BorderSide(color: t.border)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            style: TextStyle(color: t.text, fontSize: 14),
                            onSubmitted: (_) => _send(),
                            textInputAction: TextInputAction.send,
                            decoration: const InputDecoration(
                              hintText: 'Type your question…',
                            ),
                          ),
                        ),
                        const SizedBox(width: SenseiTokens.gapSm),
                        Material(
                          color: t.accent,
                          borderRadius: SenseiTokens.brSm,
                          child: InkWell(
                            onTap: _send,
                            borderRadius: SenseiTokens.brSm,
                            child: Padding(
                              padding: const EdgeInsets.all(SenseiTokens.gapMd),
                              child: Icon(
                                Icons.send_rounded,
                                color: t.onAccent,
                                size: 19,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Msg msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final mine = msg.isUser;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: SenseiTokens.gapXs),
        padding: const EdgeInsets.symmetric(
          horizontal: SenseiTokens.gapMd + 2,
          vertical: SenseiTokens.gapMd - 1,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.80,
        ),
        decoration: BoxDecoration(
          color: mine ? t.accent : t.surface,
          border: mine ? null : Border.all(color: t.border),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(SenseiTokens.radiusMd),
            topRight: const Radius.circular(SenseiTokens.radiusMd),
            bottomLeft: Radius.circular(mine ? SenseiTokens.radiusMd : 4),
            bottomRight: Radius.circular(mine ? 4 : SenseiTokens.radiusMd),
          ),
        ),
        child: Text(
          msg.text,
          style: TextStyle(
            color: mine ? t.onAccent : t.textSecondary,
            fontSize: 13,
            height: 1.5,
            fontWeight: mine ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  final AnimationController controller;
  const _TypingBubble(this.controller);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: SenseiTokens.gapXs),
        padding: const EdgeInsets.symmetric(
          horizontal: SenseiTokens.gap,
          vertical: SenseiTokens.gapMd,
        ),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(SenseiTokens.radiusMd),
            topRight: Radius.circular(SenseiTokens.radiusMd),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(SenseiTokens.radiusMd),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: AnimatedBuilder(
                animation: controller,
                builder: (_, child) {
                  final phase = (controller.value + i * 0.2) % 1.0;
                  final lift = 0.5 - (phase - 0.5).abs();
                  return Transform.translate(
                    offset: Offset(0, -6 * lift),
                    child: Opacity(opacity: 0.35 + lift * 1.2, child: child),
                  );
                },
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _Msg {
  final String text;
  final bool isUser;
  _Msg(this.text, this.isUser);
}
