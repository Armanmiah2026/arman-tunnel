import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../services/config_service.dart';
import '../services/tunnel_http_client.dart';
import '../theme/sensei_theme.dart';
import '../utils/format.dart';
import '../utils/user_error.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/sensei_controls.dart';
import '../widgets/ui/sensei_modal.dart';

/// Logical grouping of the protocols for the manual form.
enum _Family { v2ray, ssh, openvpn, udp, wireguard, psiphon }

enum _Mode { import, manual }

class AddConfigScreen extends StatefulWidget {
  final ServerConfig? editConfig;

  const AddConfigScreen({super.key, this.editConfig});

  @override
  State<AddConfigScreen> createState() => _AddConfigScreenState();
}

class _AddConfigScreenState extends State<AddConfigScreen> {
  // ---- Controllers ----
  final _importController = TextEditingController();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _portController = TextEditingController();
  final _uuidController = TextEditingController();
  final _alterIdController = TextEditingController();
  final _sniController = TextEditingController();
  final _pathController = TextEditingController();
  final _hostController = TextEditingController();
  final _serviceNameController = TextEditingController();
  final _publicKeyController = TextEditingController();
  final _shortIdController = TextEditingController();
  final _flowController = TextEditingController();
  final _payloadController = TextEditingController();
  final _proxyHostController = TextEditingController();
  final _proxyPortController = TextEditingController();
  final _sshUserController = TextEditingController();
  final _sshPassController = TextEditingController();
  final _dnsttServerController = TextEditingController();
  final _dnsttKeyController = TextEditingController();
  final _dnsttResolverController = TextEditingController(text: '1.1.1.1:53');
  final _ovpnController = TextEditingController();
  final _wgController = TextEditingController();
  final _hyperAuthController = TextEditingController();

  // ---- Selections ----
  ProtocolType _protocol = ProtocolType.vless;
  TransportType _transport = TransportType.tcp;
  String _vmessSecurity = 'auto'; // encryption for VMess
  String _fingerprint = 'chrome'; // uTLS fingerprint for TLS/REALITY

  // ---- Toggles / dynamic state ----
  bool _isImportMode = true;

  // ---- Custom Tweak: ride an OFFICIAL server instead of entering one ----
  // When on, the endpoint/credential fields are optional — the tweak joins
  // at connect time with the first official server whose capability types
  // include the picked one (exactly the admin panel's dynamic join).
  bool _useOfficialServer = false;
  String? _officialCapability;

  /// Official server this tweak rides (panel-style preferred anchor). When
  /// null/unknown the first compatible server of the type is used.
  String? _officialAnchorId;
  bool _officialUseSni = false;
  bool _officialUsePayload = false;
  bool _officialUseProxy = false;
  bool _officialEnhanced = false;
  bool _obscurePass = true;

  // SSH
  bool _sshUseSsl = false;
  bool _sshUsePayload = false;
  bool _sshUseProxy = false;
  bool _sshUseDnstt = false;
  bool _sshEnhanced = false; // enhanced (split-send) payload
  bool _sshCompression = false; // zlib compression

  // OpenVPN
  String _ovpnFileName = '';
  bool _ovpnRequiresAuth = false;
  bool _ovpnUseSsl = false; // wrap OpenVPN TCP in TLS w/ spoofed SNI
  bool _ovpnUsePayload = false;
  bool _ovpnUseProxy = false;
  bool _ovpnEnhanced = false;

  // WireGuard / Psiphon / UDP (Hysteria)
  String _wgFileName = '';
  String _psiphonRegion = 'US';

  /// Region → human name + the first upstream host PsiphonEngine dials for
  /// it (mirror of the Kotlin psiphonServers map — display only, the engine
  /// picks the host itself).
  static const Map<String, String> _psiphonRegionNames = {
    'US': 'United States',
    'GB': 'United Kingdom',
    'DE': 'Germany',
    'JP': 'Japan',
    'SG': 'Singapore',
  };
  static const Map<String, String> _psiphonHosts = {
    'US': 'psiphon.us',
    'GB': 'psiphon.uk',
    'DE': 'psiphon.de',
    'JP': 'psiphon.jp',
    'SG': 'psiphon.sg',
  };

  /// `Endpoint = host:port` line of a wg .conf [Peer] section.
  static final RegExp _wgEndpointRe = RegExp(
    r'^\s*endpoint\s*=\s*([A-Za-z0-9.\-]+):(\d{1,5})\s*$',
    multiLine: true,
    caseSensitive: false,
  );

  // V2Ray
  SecurityType _v2raySecurity = SecurityType.none;
  bool _v2rayUsePayload = false;
  bool _v2rayUseProxy = false;
  bool _v2rayEnhanced = false;

  _Family get _family {
    switch (_protocol) {
      case ProtocolType.ssh:
      case ProtocolType.sshDnstt:
        return _Family.ssh;
      case ProtocolType.openvpn:
        return _Family.openvpn;
      case ProtocolType.wireguard:
        return _Family.wireguard;
      case ProtocolType.psiphon:
        return _Family.psiphon;
      case ProtocolType.hysteria:
        return _Family.udp;
      default:
        return _Family.v2ray;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.editConfig != null) {
      _isImportMode = false;
      _prefillFromConfig(widget.editConfig!);
    }
  }

  void _prefillFromConfig(ServerConfig cfg) {
    final cfgSvc = context.read<ConfigService>();
    if (cfgSvc.isOfficialTweak(cfg)) {
      _useOfficialServer = true;
      _officialCapability = (cfg.capability ?? '').trim().toUpperCase();
      _officialAnchorId = cfg.anchorId;
      _officialUseSni = (cfg.sni ?? '').isNotEmpty;
      _officialUsePayload = (cfg.payload ?? '').isNotEmpty;
      _officialUseProxy = (cfg.injectHost ?? '').isNotEmpty;
      _officialEnhanced = cfg.payloadEnhanced;
    }
    _protocol = cfg.protocol;
    _transport = cfg.transport;
    _nameController.text = cfg.name;
    _addressController.text = cfg.address;
    _portController.text = cfg.port.toString();
    _uuidController.text = cfg.uuid;
    _alterIdController.text = cfg.alterId ?? '';
    _vmessSecurity = cfg.encryption ?? 'auto';
    _v2raySecurity = cfg.security;
    _fingerprint = (cfg.fingerprint != null && cfg.fingerprint!.isNotEmpty)
        ? cfg.fingerprint!
        : 'chrome';
    _sniController.text = cfg.sni ?? '';
    _pathController.text = cfg.path ?? '';
    _hostController.text = cfg.host ?? '';
    _serviceNameController.text = cfg.serviceName ?? '';
    _publicKeyController.text = cfg.publicKey ?? '';
    _shortIdController.text = cfg.shortId ?? '';
    _flowController.text = cfg.flow ?? '';
    _payloadController.text = cfg.payload ?? '';
    _proxyHostController.text = cfg.injectHost ?? '';
    _proxyPortController.text = cfg.injectPort ?? '';
    _sshUserController.text = cfg.sshUser ?? '';
    _sshPassController.text = cfg.sshPass ?? '';
    _dnsttServerController.text = cfg.dnsttServer ?? '';
    _dnsttKeyController.text = cfg.dnsttKey ?? '';
    _dnsttResolverController.text = cfg.dnsttResolver ?? '1.1.1.1:53';
    _ovpnController.text = cfg.ovpnConfig ?? '';
    _wgController.text = cfg.wireguardConfig ?? '';
    _hyperAuthController.text =
        cfg.protocol == ProtocolType.hysteria ? (cfg.password ?? '') : '';
    final region = (cfg.psiphonRegion ?? '').trim().toUpperCase();
    _psiphonRegion = _psiphonRegionNames.containsKey(region) ? region : 'US';

    _sshUseSsl = cfg.injectMode == InjectMode.directSni || cfg.injectMode == InjectMode.proxySni;
    _sshUseProxy = cfg.injectMode == InjectMode.proxy || cfg.injectMode == InjectMode.proxySni;
    _sshUsePayload = cfg.payload != null && cfg.payload!.isNotEmpty;
    _sshUseDnstt = cfg.protocol == ProtocolType.sshDnstt;
    _sshEnhanced = cfg.payloadEnhanced;
    _sshCompression = cfg.sshCompression;

    _ovpnUseSsl = cfg.injectMode == InjectMode.directSni || cfg.injectMode == InjectMode.proxySni;
    _ovpnUseProxy = cfg.injectMode == InjectMode.proxy || cfg.injectMode == InjectMode.proxySni;
    _ovpnUsePayload = cfg.payload != null && cfg.payload!.isNotEmpty;
    _ovpnEnhanced = cfg.payloadEnhanced;
    _ovpnRequiresAuth = (cfg.sshUser != null && cfg.sshUser!.isNotEmpty) ||
        RegExp(r'^\s*auth-user-pass\s*$', multiLine: true)
            .hasMatch(cfg.ovpnConfig ?? '');

    _v2rayUseProxy = cfg.injectMode == InjectMode.proxy || cfg.injectMode == InjectMode.proxySni;
    _v2rayUsePayload = cfg.payload != null && cfg.payload!.isNotEmpty;
    _v2rayEnhanced = cfg.payloadEnhanced;
  }

  @override
  void dispose() {
    for (final c in [
      _importController,
      _nameController,
      _addressController,
      _portController,
      _uuidController,
      _alterIdController,
      _sniController,
      _pathController,
      _hostController,
      _serviceNameController,
      _publicKeyController,
      _shortIdController,
      _flowController,
      _payloadController,
      _proxyHostController,
      _proxyPortController,
      _sshUserController,
      _sshPassController,
      _dnsttServerController,
      _dnsttKeyController,
      _dnsttResolverController,
      _ovpnController,
      _wgController,
      _hyperAuthController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ===========================================================================
  // Actions
  // ===========================================================================

  /// Ask for the PIN of a user-locked share. The lock-check marker lets the
  /// user retry without importing on a typo, but the real verification is
  /// the decrypt itself (a wrong PIN fails the AES-GCM tag).
  Future<String?> _askLockPin(String text) {
    return SenseiModal.edit(
      context,
      title: 'Locked config',
      description: 'This config is locked by its sharer. Enter the PIN they '
          'gave you to open it.',
      fields: const [
        SenseiModalField(label: 'Lock PIN', hint: 'required'),
      ],
      saveLabel: 'Unlock & import',
    ).then((out) => (out == null || out.isEmpty) ? null : out.first.trim());
  }

  /// V2Ray "Import from Clipboard": parse a vmess:// / vless:// / trojan:// /
  /// ss:// link and pre-fill the form WITHOUT persisting it yet. Every field
  /// the parser found is carried over — not just the basic dozen.
  Future<void> _prefillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      AppToast.error(context, 'Clipboard is empty.');
      return;
    }
    final cfg =
        Provider.of<ConfigService>(context, listen: false).parseForPrefill(text);
    if (cfg == null) {
      AppToast.error(context, 'No valid vmess/vless/trojan/ss link found.');
      return;
    }
    setState(() {
      _protocol = cfg.protocol;
      _transport = cfg.transport;
      _nameController.text = cfg.displayName;
      _addressController.text = cfg.address;
      _portController.text = cfg.port.toString();
      _uuidController.text = cfg.uuid;
      if (cfg.password != null && cfg.password!.isNotEmpty) {
        _uuidController.text = cfg.password!;
      }
      _alterIdController.text = cfg.alterId ?? '';
      _vmessSecurity = cfg.encryption ?? 'auto';
      _v2raySecurity = cfg.security;
      _fingerprint = (cfg.fingerprint != null && cfg.fingerprint!.isNotEmpty)
          ? cfg.fingerprint!
          : (_v2raySecurity == SecurityType.none ? '' : 'chrome');
      _sniController.text = cfg.sni ?? '';
      _pathController.text = cfg.path ?? '';
      _hostController.text = cfg.host ?? '';
      _serviceNameController.text = cfg.serviceName ?? '';
      _publicKeyController.text = cfg.publicKey ?? '';
      _shortIdController.text = cfg.shortId ?? '';
      _flowController.text = cfg.flow ?? '';
      if (cfg.protocol == ProtocolType.hysteria) {
        _hyperAuthController.text = cfg.password ?? '';
      }
    });
    AppToast.success(context, 'Filled fields from clipboard.');
  }

  Future<void> _pickOvpnFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      String content = '';
      if (f.bytes != null) {
        content = utf8.decode(f.bytes!, allowMalformed: true);
      } else if (f.path != null) {
        content = await File(f.path!).readAsString();
      }
      if (!mounted) return;
      setState(() {
        // In Import mode this must fill the IMPORT box (the button lives
        // there); writing only the hidden manual-form controller used to make
        // the whole flow a no-op that still toasted "Loaded".
        if (_isImportMode) {
          _importController.text = content;
        } else {
          _ovpnController.text = content;
          _protocol = ProtocolType.openvpn;
        }
        _ovpnFileName = f.name;
        if (_nameController.text.trim().isEmpty) {
          _nameController.text = f.name
              .replaceAll(RegExp(r'\.(ovpn|st|cfg|txt)$', caseSensitive: false), '');
        }
        // OpenVPN profiles with a bare `auth-user-pass` line need manual creds.
        if (RegExp(r'^\s*auth-user-pass\s*$', multiLine: true)
            .hasMatch(content)) {
          _ovpnRequiresAuth = true;
        }
      });
      AppToast.success(context, 'Loaded: ${f.name} — tap Import');
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          UserError.withRaw(
              'Could not read that file.', UserError.showRaw ? e : null),
        );
      }
    }
  }

  Future<void> _pickWgFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      String content = '';
      if (f.bytes != null) {
        content = utf8.decode(f.bytes!, allowMalformed: true);
      } else if (f.path != null) {
        content = await File(f.path!).readAsString();
      }
      if (!mounted) return;
      setState(() {
        _wgController.text = content;
        _protocol = ProtocolType.wireguard;
        _wgFileName = f.name;
        if (_nameController.text.trim().isEmpty) {
          _nameController.text = f.name
              .replaceAll(RegExp(r'\.(conf|wg|txt)$', caseSensitive: false), '');
        }
      });
      AppToast.success(context, 'Loaded: ${f.name} — tap Save');
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          UserError.withRaw(
              'Could not read that file.', UserError.showRaw ? e : null),
        );
      }
    }
  }

  /// Parsed `[Peer]` endpoint of the pasted wg .conf (host group 1, port
  /// group 2) — the engine dials it straight, the form just surfaces it.
  RegExpMatch? get _wgEndpoint => _wgEndpointRe.firstMatch(_wgController.text);

  void _generateUuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    final uuid = '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-'
        '${h(6)}${h(7)}-${h(8)}${h(9)}-'
        '${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
    setState(() => _uuidController.text = uuid);
  }

  String? _validate() {
    if (_nameController.text.trim().isEmpty) return 'Name is required.';
    if (_useOfficialServer) {
      final hasType = (_officialCapability ?? '').trim().isNotEmpty;
      if (!hasType) return 'Pick a tweak type.';
      if (_officialUseSni && _sniController.text.trim().isEmpty) {
        return 'SNI is required when Use SNI is enabled.';
      }
      if (_officialUsePayload && _payloadController.text.trim().isEmpty) {
        return 'Payload is required when Use Payload is enabled.';
      }
      return null;
    }
    // The server address is OPTIONAL when the config reaches the network
    // through an inject host (proxy / bug host): SNI-only, payload-only or
    // proxy-mode tunnels dial the injector front, not the raw address —
    // exactly how community SNI/payload configs are shared. The engine
    // validates the pair at connect time.
    bool addressOptional(_Family f) {
      final hasFront = _sshUseProxy || _v2rayUseProxy || _ovpnUseProxy;
      final hasSni = _sniController.text.trim().isNotEmpty &&
          (_sshUseSsl || _ovpnUseSsl);
      final hasPayload = _payloadController.text.trim().isNotEmpty &&
          (_sshUsePayload || _v2rayUsePayload || _ovpnUsePayload);
      return hasFront || hasSni || hasPayload;
    }

    switch (_family) {
      case _Family.v2ray:
        if (_addressController.text.trim().isEmpty &&
            !addressOptional(_Family.v2ray)) {
          return 'Address is required (or add SNI / payload / proxy).';
        }
        if (_portController.text.trim().isEmpty) return 'Port is required.';
        if (_uuidController.text.trim().isEmpty) {
          return _protocol == ProtocolType.trojan
              ? 'Password is required.'
              : 'UUID is required.';
        }
        break;
      case _Family.ssh:
        if (_addressController.text.trim().isEmpty &&
            !addressOptional(_Family.ssh)) {
          return 'Host is required (or add SNI / payload / proxy).';
        }
        if (_portController.text.trim().isEmpty) return 'Port is required.';
        if (_sshUserController.text.trim().isEmpty) {
          return 'Username is required.';
        }
        if (_sshUseDnstt && _dnsttServerController.text.trim().isEmpty) {
          return 'DNSTT nameserver is required.';
        }
        break;
      case _Family.openvpn:
        if (_ovpnController.text.trim().isEmpty) {
          return 'Pick or paste an .ovpn profile.';
        }
        if (_ovpnRequiresAuth && _sshUserController.text.trim().isEmpty) {
          return 'This profile needs a username/password.';
        }
        break;
      case _Family.udp:
        if (_addressController.text.trim().isEmpty) {
          return 'Address is required.';
        }
        if (_portController.text.trim().isEmpty) return 'Port is required.';
        break;
      case _Family.wireguard:
        final conf = _wgController.text.trim();
        if (conf.isEmpty) {
          return 'Pick or paste a WireGuard (.conf) config.';
        }
        // Same gate as the panel's config-schema: a client config must carry
        // its own [Interface] keys; the [Peer] Endpoint is what we dial.
        if (!RegExp(r'^\s*\[Interface\]', multiLine: true).hasMatch(conf)) {
          return 'Missing [Interface] section — paste the full wg config.';
        }
        if (_wgEndpoint == null) {
          return 'Missing [Peer] Endpoint (host:port) — nothing to dial.';
        }
        break;
      case _Family.psiphon:
        // No endpoint/credentials: the region dropdown always holds a value.
        break;
    }
    return null;
  }

  String? _proxyHostOrDefault(bool useProxy) {
    if (!useProxy) return null;
    final host = _proxyHostController.text.trim();
    return host.isEmpty ? kDefaultProxyHost : host;
  }

  String? _proxyPortOrDefault(bool useProxy) {
    if (!useProxy) return null;
    final port = _proxyPortController.text.trim();
    return port.isEmpty ? kDefaultProxyPort : port;
  }

  /// Resolve the SSH inject mode from the toggles.
  InjectMode _officialInjectMode() {
    if (_officialUseProxy && _officialUseSni) return InjectMode.proxySni;
    if (_officialUseProxy) return InjectMode.proxy;
    if (_officialUseSni) return InjectMode.directSni;
    if (_officialUsePayload) return InjectMode.direct;
    return InjectMode.none;
  }

  InjectMode _sshInjectMode() {
    if (_sshUseProxy && _sshUseSsl) return InjectMode.proxySni;
    if (_sshUseProxy) return InjectMode.proxy;
    if (_sshUseSsl) return InjectMode.directSni;
    if (_sshUsePayload) return InjectMode.direct;
    return InjectMode.none;
  }

  /// OpenVPN inject mode — the relay wraps the OpenVPN TCP in TLS for SNI modes.
  InjectMode _ovpnInjectMode() {
    if (_ovpnUseProxy && _ovpnUseSsl) return InjectMode.proxySni;
    if (_ovpnUseProxy) return InjectMode.proxy;
    if (_ovpnUseSsl) return InjectMode.directSni;
    if (_ovpnUsePayload) return InjectMode.direct;
    return InjectMode.none;
  }

  /// The profile speaks UDP (proto udp or a `remote … udp` override) — the
  /// payload injector is a TCP relay, so DPI bypass cannot apply to it.
  bool get _ovpnProfileIsUdp {
    final text = _ovpnController.text;
    return RegExp(r'^\s*proto\s+udp', multiLine: true, caseSensitive: false)
            .hasMatch(text) ||
        RegExp(r'^\s*remote\s+\S+(?:\s+\d+)?\s+udp',
                multiLine: true, caseSensitive: false)
            .hasMatch(text);
  }

  /// V2Ray inject mode — TLS/SNI is handled by xray, so the injector only does
  /// the HTTP payload (direct) or bug-host proxy.
  InjectMode _v2rayInjectMode() {
    if (_v2rayUseProxy) return InjectMode.proxy;
    if (_v2rayUsePayload) return InjectMode.direct;
    // No DPI toggle touched: PRESERVE the imported/existing explicit mode.
    // SSL(TCP) imports carry directSni with a blank payload — recomputing
    // from scratch here downgraded it to none and killed the tunnel on edit.
    const preservable = [InjectMode.direct, InjectMode.directSni];
    final original = widget.editConfig?.injectMode;
    if (original != null && preservable.contains(original)) return original;
    return InjectMode.none;
  }

  void _save() {
    final err = _validate();
    if (err != null) {
      AppToast.error(context, err);
      return;
    }
    final name = _nameController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 443;
    final id = widget.editConfig?.id ??
        DateTime.now().millisecondsSinceEpoch.toString();

    if (_useOfficialServer) {
      final type = ServerConfig.capabilityKey(_officialCapability ?? '');
      final cfgSvc = context.read<ConfigService>();
      final candidates = cfgSvc.officialServers
          .where((s) => s.supportsCapability(type))
          .toList();
      if (candidates.isEmpty) {
        AppToast.error(context,
            'No official server supports [$type] — pick another type.');
        return;
      }
      final anchor = candidates.firstWhere(
        (s) => s.id == _officialAnchorId,
        orElse: () => candidates.first,
      );
      final config = ConfigService.officialTweakPlaceholder(ServerConfig(
        id: id,
        name: name,
        note: name,
        // The tweak rides THIS server — carry its identity so the family
        // join (capability + protocol family, panel rule) can never drift
        // onto another node family.
        protocol: anchor.protocol,
        transport: anchor.transport,
        security: anchor.security,
        anchorId: anchor.id,
        address: '',
        port: 443,
        capability: type,
        sni: _officialUseSni && _sniController.text.trim().isNotEmpty
            ? _sniController.text.trim()
            : null,
        payload: _officialUsePayload && _payloadController.text.trim().isNotEmpty
            ? _payloadController.text.trim()
            : null,
        injectHost: _proxyHostOrDefault(_officialUseProxy),
        injectPort: _proxyPortOrDefault(_officialUseProxy),
        injectMode: _officialInjectMode(),
        payloadEnhanced: _officialUsePayload && _officialEnhanced,
        isCustom: true,
        isOfficial: false,
      ));
      if (widget.editConfig != null) {
        Provider.of<ConfigService>(context, listen: false)
            .updateCustomServer(config);
        AppToast.success(context, 'Updated: ${config.displayName}');
      } else {
        Provider.of<ConfigService>(context, listen: false).addCustomServer(config);
        AppToast.success(context, 'Added: ${config.displayName}');
      }
      Navigator.pop(context);
      return;
    }

    // Start from the existing config (when editing) so fields this form does
    // not render are PRESERVED, then apply the family-specific overrides.
    ServerConfig config = widget.editConfig ??
        ServerConfig(
          id: id,
          name: name,
          protocol: _protocol,
          address: _addressController.text.trim(),
          port: port,
        );

    switch (_family) {
      case _Family.v2ray:
        final isTrojan = _protocol == ProtocolType.trojan;
        final secret = _uuidController.text.trim();
        config = config.copyWith(
          id: id,
          name: name,
          note: name,
          protocol: _protocol,
          transport: _transport,
          security: _v2raySecurity,
          address: _addressController.text.trim(),
          port: port,
          uuid: secret,
          password: isTrojan || _protocol == ProtocolType.shadowsocks
              ? secret
              : config.password,
          alterId: _protocol == ProtocolType.vmess
              ? (_alterIdController.text.trim().isEmpty
                  ? '0'
                  : _alterIdController.text.trim())
              : null,
          encryption: _protocol == ProtocolType.vmess
              ? _vmessSecurity
              : (_protocol == ProtocolType.vless
                  ? 'none'
                  : (_protocol == ProtocolType.shadowsocks
                      ? (_vmessSecurity == 'auto'
                          ? 'aes-256-gcm'
                          : _vmessSecurity)
                      : null)),
          sni: _v2raySecurity != SecurityType.none &&
                  _sniController.text.trim().isNotEmpty
              ? _sniController.text.trim()
              : null,
          host: _hostController.text.trim().isNotEmpty
              ? _hostController.text.trim()
              : null,
          path: _transport == TransportType.ws &&
                  _pathController.text.trim().isNotEmpty
              ? _pathController.text.trim()
              : null,
          serviceName: _transport == TransportType.grpc &&
                  _serviceNameController.text.trim().isNotEmpty
              ? _serviceNameController.text.trim()
              : null,
          fingerprint:
              _v2raySecurity != SecurityType.none ? _fingerprint : null,
          flow: _flowController.text.trim().isNotEmpty
              ? _flowController.text.trim()
              : null,
          publicKey: _v2raySecurity == SecurityType.reality &&
                  _publicKeyController.text.trim().isNotEmpty
              ? _publicKeyController.text.trim()
              : null,
          shortId: _v2raySecurity == SecurityType.reality &&
                  _shortIdController.text.trim().isNotEmpty
              ? _shortIdController.text.trim()
              : null,
          injectMode: _v2rayInjectMode(),
          payload: _v2rayUsePayload && _payloadController.text.trim().isNotEmpty
              ? _payloadController.text.trim()
              : null,
          injectHost: _proxyHostOrDefault(_v2rayUseProxy),
          injectPort: _proxyPortOrDefault(_v2rayUseProxy),
          payloadEnhanced: _v2rayUsePayload && _v2rayEnhanced,
          isCustom: true,
        );
        break;

      case _Family.ssh:
        final mode = _sshInjectMode();
        config = config.copyWith(
          id: id,
          name: name,
          note: name,
          protocol:
              _sshUseDnstt ? ProtocolType.sshDnstt : ProtocolType.ssh,
          address: _addressController.text.trim(),
          port: port,
          sshUser: _sshUserController.text.trim(),
          sshPass: _sshPassController.text,
          injectMode: mode,
          sni: _sshUseSsl && _sniController.text.trim().isNotEmpty
              ? _sniController.text.trim()
              : null,
          payload: _sshUsePayload && _payloadController.text.trim().isNotEmpty
              ? _payloadController.text.trim()
              : null,
          injectHost: _proxyHostOrDefault(_sshUseProxy),
          injectPort: _proxyPortOrDefault(_sshUseProxy),
          dnsttServer: _sshUseDnstt &&
                  _dnsttServerController.text.trim().isNotEmpty
              ? _dnsttServerController.text.trim()
              : null,
          dnsttKey:
              _sshUseDnstt && _dnsttKeyController.text.trim().isNotEmpty
                  ? _dnsttKeyController.text.trim()
                  : null,
          dnsttResolver: _sshUseDnstt &&
                  _dnsttResolverController.text.trim().isNotEmpty
              ? _dnsttResolverController.text.trim()
              : null,
          payloadEnhanced: _sshUsePayload && _sshEnhanced,
          sshCompression: _sshCompression,
          isCustom: true,
        );
        break;

      case _Family.openvpn:
        final ovpn = _ovpnController.text.trim();
        final remote =
            RegExp(r'^\s*remote\s+(\S+)(?:\s+(\d+))?', multiLine: true)
                .firstMatch(ovpn);
        config = config.copyWith(
          id: id,
          name: name,
          note: name,
          protocol: ProtocolType.openvpn,
          transport: TransportType.tcp,
          security: SecurityType.none,
          address: remote?.group(1) ?? _addressController.text.trim(),
          port: int.tryParse(remote?.group(2) ?? '') ?? port,
          ovpnConfig: ovpn,
          sshUser: _ovpnRequiresAuth ? _sshUserController.text.trim() : null,
          sshPass: _ovpnRequiresAuth ? _sshPassController.text : null,
          injectMode: _ovpnInjectMode(),
          sni: _ovpnUseSsl && _sniController.text.trim().isNotEmpty
              ? _sniController.text.trim()
              : null,
          payload: _ovpnUsePayload && _payloadController.text.trim().isNotEmpty
              ? _payloadController.text.trim()
              : null,
          injectHost: _proxyHostOrDefault(_ovpnUseProxy),
          injectPort: _proxyPortOrDefault(_ovpnUseProxy),
          payloadEnhanced: _ovpnUsePayload && _ovpnEnhanced,
          isCustom: true,
        );
        break;

      case _Family.udp:
        // Mirror of _parseHysteriaLink: auth rides `password`, empty SNI =
        // insecure (accept any cert) exactly like toHysteriaConfig expects.
        final auth = _hyperAuthController.text.trim();
        final hySni = _sniController.text.trim();
        config = config.copyWith(
          id: id,
          name: name,
          note: name,
          protocol: ProtocolType.hysteria,
          transport: TransportType.tcp,
          security: hySni.isEmpty ? SecurityType.none : SecurityType.tls,
          address: _addressController.text.trim(),
          port: port,
          password: auth,
          sni: hySni.isEmpty ? null : hySni,
          payload: null,
          injectHost: null,
          injectPort: null,
          injectMode: InjectMode.none,
          isCustom: true,
        );
        break;

      case _Family.wireguard:
        final conf = _wgController.text.trim();
        final ep = _wgEndpoint;
        config = config.copyWith(
          id: id,
          name: name,
          note: name,
          protocol: ProtocolType.wireguard,
          transport: TransportType.tcp,
          security: SecurityType.none,
          address: ep?.group(1) ?? _addressController.text.trim(),
          port: int.tryParse(ep?.group(2) ?? '') ?? port,
          wireguardConfig: conf,
          payload: null,
          injectHost: null,
          injectPort: null,
          injectMode: InjectMode.none,
          isCustom: true,
        );
        break;

      case _Family.psiphon:
        config = config.copyWith(
          id: id,
          name: name,
          note: name,
          protocol: ProtocolType.psiphon,
          transport: TransportType.tcp,
          security: SecurityType.none,
          // Address is display-only — PsiphonEngine dials the region's own
          // host list, keyed by psiphonRegion. Keep them visually in sync.
          address: _psiphonHosts[_psiphonRegion] ?? _psiphonHosts['US']!,
          port: 443,
          psiphonRegion: _psiphonRegion,
          payload: null,
          injectHost: null,
          injectPort: null,
          injectMode: InjectMode.none,
          isCustom: true,
        );
        break;
    }

    if (widget.editConfig != null) {
      Provider.of<ConfigService>(context, listen: false).updateCustomServer(config);
      AppToast.success(context, 'Updated: ${config.displayName}');
    } else {
      Provider.of<ConfigService>(context, listen: false).addCustomServer(config);
      AppToast.success(context, 'Added: ${config.displayName}');
    }
    Navigator.pop(context);
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: Text(widget.editConfig != null ? 'Edit Configuration' : 'Add Configuration'),
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
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SenseiTokens.pageInset,
                  SenseiTokens.gapMd,
                  SenseiTokens.pageInset,
                  SenseiTokens.gapSm,
                ),
                child: SenseiSegmented<_Mode>(
                  values: const [_Mode.import, _Mode.manual],
                  selected: _isImportMode ? _Mode.import : _Mode.manual,
                  onChanged: (m) => setState(() => _isImportMode = m == _Mode.import),
                  label: (m) => m == _Mode.import ? 'Import' : 'Manual',
                  iconFor: (m) => m == _Mode.import
                      ? Icons.paste_rounded
                      : Icons.edit_note_rounded,
                ),
              ),
              Expanded(
                child: _isImportMode ? _buildImportForm() : _buildManualForm(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Import tab ----------------------------------------------------------

  Widget _buildImportForm() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: SenseiTokens.maxContentWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SenseiTokens.pageInset,
            SenseiTokens.gapMd,
            SenseiTokens.pageInset,
            SenseiTokens.gapXxl * 2,
          ),
          children: [
            const SenseiNotice(
              message:
                  'Copy a config anywhere — then tap Import from Clipboard. '
                  'Supports armantunnel:// shares (incl. locked), protocol '
                  'links, and .st / .ovpn files.',
            ),
            const SizedBox(height: SenseiTokens.gapLg),
            // The primary action: read the SHARE STRING straight from the
            // system clipboard and import it — no manual paste box (the box
            // is gone by design; the clipboard IS the input).
            SenseiPrimaryButton(
              label: 'Import from Clipboard',
              icon: Icons.content_paste_rounded,
              onPressed: _importFromClipboard,
            ),
            const SizedBox(height: SenseiTokens.gapMd),
            OutlinedButton.icon(
              onPressed: _pickOvpnFile,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Pick .st / .ovpn file'),
            ),
            const SizedBox(height: SenseiTokens.gapXl),
            // Manual entry stays available as the second tab — the paste
            // box was the only redundant path.
            Center(
              child: Text(
                'Building one by hand? Switch to the Manual tab.',
                style: TextStyle(
                  color: context.tokens.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// THE import action: read the config/share string from the system
  /// clipboard and run it through the one parser. Password-gated shares
  /// (legacy v2p or v48) throw LockPinRequired — the password is asked for
  /// and the import retried, so multi-line exports with a gated line work
  /// too. A URL in the clipboard is downloaded and imported.
  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    var text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      AppToast.error(context, 'Clipboard is empty — copy a config first.');
      return;
    }
    // A URL (e.g. a panel's .ovpn / account file link): download it and
    // import whatever comes back.
    if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        final resp = await TunnelHttpClient.get(
          Uri.parse(text),
          timeout: const Duration(seconds: 15),
        );
        if (resp.statusCode != 200 || resp.body.trim().isEmpty) {
          if (mounted) {
            AppToast.error(context, 'Download failed: HTTP ${resp.statusCode}');
          }
          return;
        }
        text = resp.body.trim();
        if (!mounted) return;
      } catch (e) {
        if (mounted) {
          AppToast.error(
            context,
            UserError.withRaw(
              'Download failed — check your connection and try again.',
              UserError.showRaw ? e : null,
            ),
          );
        }
        return;
      }
    }
    // Legacy v2p envelopes carry a pre-check marker; ask up-front for those.
    String? lockPin;
    if (isPinLockedText(text)) {
      final pin = await _askLockPin(text);
      if (pin == null || pin.isEmpty) {
        if (mounted) {
          AppToast.error(context, 'Import cancelled — password required.');
        }
        return;
      }
      lockPin = pin;
    }
    if (!mounted) return;
    final cfgSvc = context.read<ConfigService>();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await cfgSvc.importFromText(text, lockPin: lockPin);
        if (!mounted) return;
        if (r.count > 0 && r.last != null) {
          AppToast.success(
            context,
            r.count > 1
                ? 'Imported: ${r.count} configs'
                : 'Imported: ${r.last!.displayName}',
          );
          Navigator.pop(context);
        } else {
          AppToast.error(context, 'Could not import that — check the format.');
        }
        return;
      } on LockPinRequired {
        // v48 password-gated share: ask, then retry once with the password.
        if (!mounted) return;
        if (attempt > 0) {
          AppToast.error(context, 'This config is password-locked.');
          return;
        }
        final pin = await _askLockPin(text);
        if (pin == null || pin.isEmpty) {
          if (mounted) {
            AppToast.error(context, 'Import cancelled — password required.');
          }
          return;
        }
        lockPin = pin;
      } catch (e, st) {
        logImportError('manual', e, st);
        if (mounted) {
          AppToast.error(context, 'Could not import that — check the format.');
        }
        return;
      }
    }
  }

  // ---- Manual tab ----------------------------------------------------------

  Widget _buildManualForm() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: SenseiTokens.maxContentWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SenseiTokens.pageInset,
            SenseiTokens.gapMd,
            SenseiTokens.pageInset,
            SenseiTokens.gapXxl * 2,
          ),
          children: [
            _officialServerSection(),
            if (!_useOfficialServer) ...[
              _familySelector(),
              const SizedBox(height: SenseiTokens.gapLg),
            ],
            SenseiField(
              label: 'Configuration Name',
              controller: _nameController,
              hint: 'My fast server',
            ),
            if (!_useOfficialServer) ...[
              if (_family == _Family.v2ray) _v2raySection(),
              if (_family == _Family.ssh) _sshSection(),
              if (_family == _Family.openvpn) _ovpnSection(),
              if (_family == _Family.udp) _udpSection(),
              if (_family == _Family.wireguard) _wireguardSection(),
              if (_family == _Family.psiphon) _psiphonSection(),
            ],
            const SizedBox(height: SenseiTokens.gapMd),
            SenseiPrimaryButton(
              label: 'Save Configuration',
              icon: Icons.save_alt_rounded,
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }

  /// Custom Tweak: ride an OFFICIAL server by capability type instead of
  /// entering one — the tweak joins with every official server that
  /// supports the picked type (anchor first, failover pool behind it).
  Widget _officialServerSection() {
    final t = context.tokens;
    final cfg = context.watch<ConfigService>();
    // Types with at least one compatible official server, canonical keys.
    // A multi-cap node contributes every marker it genuinely supports.
    final types = {
      for (final s in cfg.officialServers) ...[
        ServerConfig.capabilityKey(s.capability ?? ''),
        ...s.capabilities.map(ServerConfig.capabilityKey),
      ]
    }
        .where((c) => c.isNotEmpty)
        .toList()
      ..sort();
    if (types.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeThumbColor: t.accent,
          title: Text(
            'Use an official server',
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            'Pick a tweak type — it rides every official server supporting '
            'it (V2Ray, SSH or OpenVPN failover included).',
            style: TextStyle(color: t.textMuted, fontSize: 11.5),
          ),
          value: _useOfficialServer,
          onChanged: (v) => setState(() {
            _useOfficialServer = v;
            if (v && (_officialCapability == null ||
                !types.contains(_officialCapability))) {
              _officialCapability = types.first;
            }
          }),
        ),
        if (_useOfficialServer) ...[
          const SizedBox(height: SenseiTokens.gapSm),
          SenseiDropdown<String>(
            label: 'Tweak type',
            value: _officialCapability != null &&
                    types.contains(_officialCapability)
                ? _officialCapability!
                : types.first,
            items: types,
            itemLabel: (c) => '[$c]',
            onChanged: (v) => setState(() {
              _officialCapability = v;
              // The anchor belongs to the OLD type — force a fresh pick.
              _officialAnchorId = null;
            }),
          ),
          Builder(builder: (ctx) {
            final type = _officialCapability != null &&
                    types.contains(_officialCapability)
                ? _officialCapability!
                : types.first;
            final pool = cfg.officialServers
                .where((s) => s.supportsCapability(type))
                .toList();
            if (pool.isEmpty) return const SizedBox.shrink();
            final desc = cfg.capabilityDescription(type);
            // The feed carries one config per tweak VARIANT — collapse them
            // into the REAL servers they ride (panel join label, falling back
            // to the endpoint for legacy feeds). The user picks a SERVER;
            // tweak variants are not servers and stay hidden.
            String keyOf(ServerConfig s) {
              final label = (s.server ?? '').trim();
              return label.isNotEmpty
                  ? 'name:$label'
                  : 'ep:${s.protocol.name}|${s.address}|${s.port}';
            }

            final rides = <ServerConfig>[];
            final seen = <String>{};
            for (final s in pool) {
              if (seen.add(keyOf(s))) rides.add(s);
            }
            final picked = pool.firstWhere(
              (s) => s.id == _officialAnchorId,
              orElse: () => rides.first,
            );
            final anchor = rides.firstWhere(
              (r) => keyOf(r) == keyOf(picked),
              orElse: () => rides.first,
            );
            final rideName = (anchor.server ?? '').trim().isNotEmpty
                ? anchor.server!.trim()
                : anchor.displayName;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (desc.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: SenseiTokens.gapSm),
                    child: Text(
                      'Description: $desc',
                      style: TextStyle(
                          color: t.textMuted, fontSize: 11.5, height: 1.35),
                    ),
                  ),
                // The Server↔Tweak rule made visible: pick the REAL server
                // this tweak rides (failover keeps the same family + type).
                SenseiDropdown<String>(
                  label: 'Server to ride',
                  value: anchor.id,
                  items: rides.map((s) => s.id).toList(),
                  itemLabel: (id) {
                    final s = rides.firstWhere((x) => x.id == id);
                    final n = (s.server ?? '').trim().isNotEmpty
                        ? s.server!.trim()
                        : s.displayName;
                    return '$n · ${s.protocolLabel}/${s.transportLabel}';
                  },
                  onChanged: (v) => setState(() => _officialAnchorId = v),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Rides $rideName '
                    '(${anchor.protocolLabel}/${anchor.transportLabel})'
                    '${rides.length - 1 > 0 ? ' + ${rides.length - 1} other same-type server${rides.length - 1 == 1 ? '' : 's'} as failover' : ''}',
                    style: TextStyle(
                        color: t.accent, fontSize: 11.5, height: 1.35),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: SenseiTokens.gapMd),
          _officialTweakFields(),
        ],
        const SizedBox(height: SenseiTokens.gapLg),
      ],
    );
  }

  Widget _officialTweakFields() {
    return _section(
      'Tweak Fields',
      Icons.tune_rounded,
      caption: 'Only these fields are saved/shared. Official server address, '
          'port and credentials are resolved from the live feed at connect time.',
      children: [
        SenseiSwitchTile(
          icon: Icons.lock_outline_rounded,
          title: 'Use SNI',
          subtitle: 'Override the official endpoint SNI / serverName.',
          value: _officialUseSni,
          onChanged: (v) => setState(() => _officialUseSni = v),
        ),
        if (_officialUseSni)
          SenseiField(
            label: 'SNI / Bug Host',
            controller: _sniController,
            hint: 'sni.host.com',
          ),
        SenseiSwitchTile(
          icon: Icons.code_rounded,
          title: 'Use Payload',
          subtitle: 'Inject a custom HTTP payload before the tunnel handshake.',
          value: _officialUsePayload,
          onChanged: (v) => setState(() => _officialUsePayload = v),
        ),
        if (_officialUsePayload) ...[
          SenseiField(
            label: 'Payload',
            controller: _payloadController,
            hint: 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]',
            maxLines: 5,
          ),
          _payloadPresetBar(),
          SenseiSwitchTile(
            icon: Icons.call_split_rounded,
            title: 'Enhanced Payload',
            subtitle: 'Split the payload across packets to dodge inline DPI.',
            value: _officialEnhanced,
            onChanged: (v) => setState(() => _officialEnhanced = v),
          ),
        ],
        SenseiSwitchTile(
          icon: Icons.hub_rounded,
          title: 'Use Proxy / Front Host',
          subtitle: 'Dial a bug/proxy host instead of the raw official endpoint.',
          value: _officialUseProxy,
          onChanged: (v) => setState(() => _officialUseProxy = v),
        ),
        if (_officialUseProxy)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: SenseiField(
                  label: 'Proxy / Front Host',
                  controller: _proxyHostController,
                  hint: kDefaultProxyHost,
                ),
              ),
              const SizedBox(width: SenseiTokens.gapMd),
              Expanded(
                flex: 1,
                child: SenseiField(
                  label: 'Port',
                  controller: _proxyPortController,
                  hint: kDefaultProxyPort,
                  number: true,
                ),
              ),
            ],
          ),
      ],
    );
  }

  static const List<(_Family, String, IconData)> _familyEntries = [
    (_Family.v2ray, 'V2Ray', Icons.bolt_rounded),
    (_Family.ssh, 'SSH', Icons.terminal_rounded),
    (_Family.openvpn, 'OpenVPN', Icons.vpn_lock_rounded),
    (_Family.udp, 'UDP', Icons.wifi_tethering_rounded),
    (_Family.wireguard, 'WireGuard', Icons.shield_moon_rounded),
    (_Family.psiphon, 'Psiphon', Icons.travel_explore_rounded),
  ];

  void _selectFamily(_Family fam) {
    switch (fam) {
      case _Family.v2ray:
        if (_family != _Family.v2ray) _protocol = ProtocolType.vless;
      case _Family.ssh:
        _protocol = _sshUseDnstt ? ProtocolType.sshDnstt : ProtocolType.ssh;
      case _Family.openvpn:
        _protocol = ProtocolType.openvpn;
      case _Family.udp:
        _protocol = ProtocolType.hysteria;
      case _Family.wireguard:
        _protocol = ProtocolType.wireguard;
      case _Family.psiphon:
        _protocol = ProtocolType.psiphon;
    }
  }

  Widget _familySelector() {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: SenseiTokens.brMd,
        border: Border.all(color: t.border),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final (fam, label, icon) in _familyEntries)
            GestureDetector(
              onTap: () => setState(() => _selectFamily(fam)),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: SenseiTokens.fast,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _family == fam ? t.accent : Colors.transparent,
                  borderRadius: SenseiTokens.brSm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon,
                        size: 15,
                        color: _family == fam ? t.onAccent : t.textMuted),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: _family == fam ? t.onAccent : t.textSecondary,
                        fontSize: 12,
                        fontWeight:
                            _family == fam ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- V2Ray ---------------------------------------------------------------

  Widget _v2raySection() {
    final t = context.tokens;
    final isVmess = _protocol == ProtocolType.vmess;
    final isTrojan = _protocol == ProtocolType.trojan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'Quick Import',
          Icons.flash_on_rounded,
          caption: 'Paste a vmess:// or vless:// link to auto-fill the fields below.',
          children: [
            SenseiPrimaryButton(
              label: 'Import from Clipboard',
              icon: Icons.content_paste_go_rounded,
              onPressed: _prefillFromClipboard,
            ),
          ],
        ),
        _section(
          'Core Details',
          Icons.dns_rounded,
          children: [
            SenseiDropdown<ProtocolType>(
              label: 'Protocol',
              value: _protocol,
              items: const [
                ProtocolType.vless,
                ProtocolType.vmess,
                ProtocolType.trojan,
                ProtocolType.shadowsocks,
              ],
              itemLabel: ProtocolVisual.labelFor,
              onChanged: (v) => setState(() => _protocol = v),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: SenseiField(
                    label: 'Address',
                    controller: _addressController,
                    hint: 'server.com / 1.2.3.4',
                  ),
                ),
                const SizedBox(width: SenseiTokens.gapMd),
                Expanded(
                  flex: 1,
                  child: SenseiField(
                    label: 'Port',
                    controller: _portController,
                    hint: '443',
                    number: true,
                  ),
                ),
              ],
            ),
            SenseiField(
              label: isTrojan ? 'Password' : 'UUID',
              controller: _uuidController,
              hint: isTrojan ? 'trojan password' : 'xxxxxxxx-xxxx-…',
              mono: !isTrojan,
              suffix: isTrojan
                  ? null
                  : IconButton(
                      tooltip: 'Generate random UUID',
                      icon: Icon(Icons.casino_outlined, size: 20,
                          color: t.accent),
                      onPressed: _generateUuid,
                    ),
            ),
            if (isVmess)
              SenseiField(
                label: 'AlterID',
                controller: _alterIdController,
                hint: '0',
                number: true,
              ),
          ],
        ),
        _section(
          'Transport & Security',
          Icons.swap_horiz_rounded,
          children: [
            SenseiDropdown<TransportType>(
              label: 'Network',
              value: _transport,
              items: TransportType.values,
              itemLabel: (tt) => tt.label,
              onChanged: (v) => setState(() => _transport = v),
            ),
            if (isVmess)
              SenseiDropdown<String>(
                label: 'Security (encryption)',
                value: _vmessSecurity,
                items: const ['none', 'auto', 'aes-128-gcm', 'chacha20-poly1305'],
                itemLabel: (s) => s,
                onChanged: (v) => setState(() => _vmessSecurity = v),
              ),
            if (_transport == TransportType.ws) ...[
              SenseiField(
                label: 'WebSocket Path',
                controller: _pathController,
                hint: '/path',
              ),
              SenseiField(
                label: 'Host Header',
                controller: _hostController,
                hint: 'cdn.host.com',
              ),
            ],
            if (_transport == TransportType.xhttp ||
                _transport == TransportType.httpUpgrade) ...[
              SenseiField(
                label: 'Path',
                controller: _pathController,
                hint: '/path',
              ),
              SenseiField(
                label: 'Host Header',
                controller: _hostController,
                hint: 'cdn.host.com',
              ),
            ],
            if (_transport == TransportType.grpc)
              SenseiField(
                label: 'gRPC Service Name',
                controller: _serviceNameController,
                hint: 'GunService',
              ),
            SenseiDropdown<SecurityType>(
              label: 'Security',
              value: _v2raySecurity,
              items: const [
                SecurityType.none,
                SecurityType.tls,
                SecurityType.reality,
              ],
              itemLabel: (s) => switch (s) {
                SecurityType.none => 'None',
                SecurityType.tls => 'TLS',
                SecurityType.reality => 'REALITY',
              },
              onChanged: (v) =>
                  setState(() {
                    _v2raySecurity = v;
                    if (v != SecurityType.none && _fingerprint.isEmpty) {
                      _fingerprint = 'chrome';
                    }
                  }),
            ),
            if (_v2raySecurity != SecurityType.none) ...[
              SenseiField(
                label: _v2raySecurity == SecurityType.reality
                    ? 'SNI / serverName'
                    : 'SNI (Server Name)',
                controller: _sniController,
                hint: 'sni.host.com',
              ),
              SenseiDropdown<String>(
                label: 'uTLS Fingerprint',
                value: _fingerprint,
                items: const [
                  'chrome',
                  'firefox',
                  'safari',
                  'ios',
                  'android',
                  'edge',
                  'randomized',
                ],
                itemLabel: (s) => s,
                onChanged: (v) => setState(() => _fingerprint = v),
              ),
            ],
            if (_v2raySecurity == SecurityType.reality) ...[
              SenseiField(
                label: 'REALITY Public Key',
                controller: _publicKeyController,
                hint: 'server public key (pbk)',
                mono: true,
              ),
              SenseiField(
                label: 'REALITY Short ID',
                controller: _shortIdController,
                hint: 'sid (optional)',
                mono: true,
              ),
            ],
            if (_protocol == ProtocolType.vless)
              SenseiField(
                label: 'Flow (XTLS)',
                controller: _flowController,
                hint: 'xtls-rprx-vision — or leave empty',
              ),
          ],
        ),
        _section(
          'DPI Bypass / Inject',
          Icons.shield_moon_rounded,
          caption: 'Front the V2Ray stream with an HTTP payload or bug-host proxy. '
              'TLS & SNI are still handled above.',
          children: [
            SenseiSwitchTile(
              icon: Icons.http_rounded,
              title: 'Use Custom Payload',
              subtitle: 'Send an HTTP request before the V2Ray handshake.',
              value: _v2rayUsePayload,
              onChanged: (v) => setState(() => _v2rayUsePayload = v),
            ),
            if (_v2rayUsePayload) ...[
              SenseiField(
                label: 'Custom Payload',
                controller: _payloadController,
                hint:
                    '[method] [host_port] [protocol][crlf]Host: [host][crlf][crlf]',
                maxLines: 5,
                mono: true,
              ),
              _payloadPresetBar(),
              SenseiSwitchTile(
                icon: Icons.call_split_rounded,
                title: 'Enhanced Payload',
                subtitle: 'Split the payload across packets to dodge inline DPI.',
                value: _v2rayEnhanced,
                onChanged: (v) => setState(() => _v2rayEnhanced = v),
              ),
            ],
            SenseiSwitchTile(
              icon: Icons.hub_rounded,
              title: 'Use Proxy',
              subtitle: 'Route through an HTTP proxy (bug host).',
              value: _v2rayUseProxy,
              onChanged: (v) => setState(() => _v2rayUseProxy = v),
            ),
            if (_v2rayUseProxy)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: SenseiField(
                      label: 'Proxy Host',
                      controller: _proxyHostController,
                      hint: kDefaultProxyHost,
                    ),
                  ),
                  const SizedBox(width: SenseiTokens.gapMd),
                  Expanded(
                    flex: 1,
                    child: SenseiField(
                      label: 'Port',
                      controller: _proxyPortController,
                      hint: kDefaultProxyPort,
                      number: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  // ---- SSH -----------------------------------------------------------------

  Widget _sshSection() {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'SSH Server',
          Icons.terminal_rounded,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: SenseiField(
                    label: 'Host / IP',
                    controller: _addressController,
                    hint: 'ssh.server.com',
                  ),
                ),
                const SizedBox(width: SenseiTokens.gapMd),
                Expanded(
                  flex: 1,
                  child: SenseiField(
                    label: 'Port',
                    controller: _portController,
                    hint: '22',
                    number: true,
                  ),
                ),
              ],
            ),
            SenseiField(
              label: 'Username',
              controller: _sshUserController,
              hint: 'username',
            ),
            SenseiField(
              label: 'Password',
              controller: _sshPassController,
              hint: '••••••••',
              obscure: _obscurePass,
              suffix: IconButton(
                icon: Icon(
                    _obscurePass ? Icons.visibility_off : Icons.visibility,
                    color: t.textMuted,
                    size: 20),
                onPressed: () => setState(() => _obscurePass = !_obscurePass),
              ),
            ),
          ],
        ),
        _section(
          'DPI Bypass',
          Icons.shield_moon_rounded,
          children: [
            SenseiSwitchTile(
              icon: Icons.enhanced_encryption_rounded,
              title: 'Use SSL / TLS',
              subtitle: 'Wrap the SSH stream in a TLS tunnel.',
              value: _sshUseSsl,
              onChanged: (v) => setState(() => _sshUseSsl = v),
            ),
            if (_sshUseSsl)
              SenseiField(
                label: 'SNI (Bug Host)',
                controller: _sniController,
                hint: 'free.bug.host.com',
              ),
            SenseiSwitchTile(
              icon: Icons.http_rounded,
              title: 'Use Custom Payload',
              subtitle: 'Inject a custom HTTP request before connecting.',
              value: _sshUsePayload,
              onChanged: (v) => setState(() => _sshUsePayload = v),
            ),
            if (_sshUsePayload) ...[
              SenseiField(
                label: 'Custom Payload',
                controller: _payloadController,
                hint:
                    '[method] [host_port] [protocol][crlf]Host: [host][crlf][crlf]',
                maxLines: 5,
                mono: true,
              ),
              _payloadPresetBar(),
              SenseiSwitchTile(
                icon: Icons.call_split_rounded,
                title: 'Enhanced Payload',
                subtitle: 'Split the payload across packets to dodge inline DPI.',
                value: _sshEnhanced,
                onChanged: (v) => setState(() => _sshEnhanced = v),
              ),
            ],
            SenseiSwitchTile(
              icon: Icons.hub_rounded,
              title: 'Use Proxy',
              subtitle: 'Route through an HTTP proxy (bug host).',
              value: _sshUseProxy,
              onChanged: (v) => setState(() => _sshUseProxy = v),
            ),
            if (_sshUseProxy)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: SenseiField(
                      label: 'Proxy Host',
                      controller: _proxyHostController,
                      hint: kDefaultProxyHost,
                    ),
                  ),
                  const SizedBox(width: SenseiTokens.gapMd),
                  Expanded(
                    flex: 1,
                    child: SenseiField(
                      label: 'Port',
                      controller: _proxyPortController,
                      hint: kDefaultProxyPort,
                      number: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
        _section(
          'Enhance',
          Icons.tune_rounded,
          children: [
            SenseiSwitchTile(
              icon: Icons.compress_rounded,
              title: 'SSH Compression',
              subtitle: 'zlib compression — helps on slow links.',
              value: _sshCompression,
              onChanged: (v) => setState(() => _sshCompression = v),
            ),
          ],
        ),
        _section(
          'SlowDNS (DNSTT)',
          Icons.dns_rounded,
          children: [
            SenseiSwitchTile(
              icon: Icons.water_rounded,
              title: 'Tunnel over DNS',
              subtitle: 'Carry SSH inside DNS queries.',
              value: _sshUseDnstt,
              onChanged: (v) => setState(() => _sshUseDnstt = v),
            ),
            if (_sshUseDnstt) ...[
              SenseiField(
                label: 'Nameserver',
                controller: _dnsttServerController,
                hint: 'ns.example.com',
              ),
              SenseiField(
                label: 'Public Key',
                controller: _dnsttKeyController,
                hint: 'hex public key',
                mono: true,
              ),
              SenseiField(
                label: 'DNS Resolver (host:port)',
                controller: _dnsttResolverController,
                hint: '1.1.1.1:53',
              ),
            ],
          ],
        ),
      ],
    );
  }

  // ---- OpenVPN -------------------------------------------------------------

  Widget _ovpnSection() {
    final t = context.tokens;
    final hasFile = _ovpnController.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'OpenVPN Profile',
          Icons.vpn_lock_rounded,
          children: [
            SenseiCard(
              onTap: _pickOvpnFile,
              radius: SenseiTokens.radiusMd,
              child: Column(
                children: [
                  Icon(hasFile ? Icons.description_rounded : Icons.upload_file_rounded,
                      color: t.accent, size: 30),
                  const SizedBox(height: SenseiTokens.gapSm),
                  Text(
                    hasFile
                        ? (_ovpnFileName.isNotEmpty ? _ovpnFileName : 'Profile loaded')
                        : 'Tap to pick a .ovpn file',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: t.text, fontSize: 13.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasFile ? 'Tap to replace' : 'or paste the profile contents below',
                    style: TextStyle(color: t.textMuted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            SenseiField(
              label: '.ovpn Contents',
              controller: _ovpnController,
              hint: 'client\nremote vpn.server.com 1194 udp\n…',
              maxLines: 6,
              mono: true,
            ),
          ],
        ),
        _section(
          'Authentication',
          Icons.password_rounded,
          children: [
            SenseiSwitchTile(
              icon: Icons.key_rounded,
              title: 'Profile requires username / password',
              subtitle: 'Enable if the .ovpn has a bare auth-user-pass line.',
              value: _ovpnRequiresAuth,
              onChanged: (v) => setState(() => _ovpnRequiresAuth = v),
            ),
            if (_ovpnRequiresAuth) ...[
              SenseiField(
                label: 'Username',
                controller: _sshUserController,
                hint: 'username',
              ),
              SenseiField(
                label: 'Password',
                controller: _sshPassController,
                hint: '••••••••',
                obscure: _obscurePass,
                suffix: IconButton(
                  icon: Icon(
                      _obscurePass ? Icons.visibility_off : Icons.visibility,
                      color: t.textMuted,
                      size: 20),
                  onPressed: () => setState(() => _obscurePass = !_obscurePass),
                ),
              ),
            ],
          ],
        ),
        _section(
          'DPI Bypass (over TCP)',
          Icons.shield_moon_rounded,
          caption: _ovpnProfileIsUdp
              ? 'This profile is UDP — DPI bypass needs TCP. Edit the profile '
                  'to proto tcp / a TCP remote to use these.'
              : 'Front the OpenVPN connection with SNI/TLS, an HTTP payload, or a '
                  'bug-host proxy. Enabling any of these forces proto TCP.',
          children: [
            SenseiSwitchTile(
              icon: Icons.enhanced_encryption_rounded,
              title: 'Use SSL / SNI',
              subtitle: 'Wrap the OpenVPN stream in TLS with a spoofed SNI.',
              value: _ovpnUseSsl,
              onChanged: (v) => setState(() => _ovpnUseSsl = v),
              enabled: !_ovpnProfileIsUdp,
            ),
            if (_ovpnUseSsl)
              SenseiField(
                label: 'SNI (Bug Host)',
                controller: _sniController,
                hint: 'free.bug.host.com',
              ),
            SenseiSwitchTile(
              icon: Icons.http_rounded,
              title: 'Use Custom Payload',
              subtitle: 'Send an HTTP request before the OpenVPN handshake.',
              value: _ovpnUsePayload,
              onChanged: (v) => setState(() => _ovpnUsePayload = v),
              enabled: !_ovpnProfileIsUdp,
            ),
            if (_ovpnUsePayload) ...[
              SenseiField(
                label: 'Custom Payload',
                controller: _payloadController,
                hint:
                    '[method] [host_port] [protocol][crlf]Host: [host][crlf][crlf]',
                maxLines: 5,
                mono: true,
              ),
              _payloadPresetBar(),
              SenseiSwitchTile(
                icon: Icons.call_split_rounded,
                title: 'Enhanced Payload',
                subtitle: 'Split the payload across packets to dodge inline DPI.',
                value: _ovpnEnhanced,
                onChanged: (v) => setState(() => _ovpnEnhanced = v),
              ),
            ],
            SenseiSwitchTile(
              icon: Icons.hub_rounded,
              title: 'Use Proxy',
              subtitle: 'Route through an HTTP proxy (bug host).',
              value: _ovpnUseProxy,
              onChanged: (v) => setState(() => _ovpnUseProxy = v),
              enabled: !_ovpnProfileIsUdp,
            ),
            if (_ovpnUseProxy)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: SenseiField(
                      label: 'Proxy Host',
                      controller: _proxyHostController,
                      hint: kDefaultProxyHost,
                    ),
                  ),
                  const SizedBox(width: SenseiTokens.gapMd),
                  Expanded(
                    flex: 1,
                    child: SenseiField(
                      label: 'Port',
                      controller: _proxyPortController,
                      hint: kDefaultProxyPort,
                      number: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  // ---- UDP (Hysteria 2) ------------------------------------------------------

  Widget _udpSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'Quick Import',
          Icons.flash_on_rounded,
          caption: 'Paste a hy2:// share link to auto-fill the fields below.',
          children: [
            SenseiPrimaryButton(
              label: 'Import hy2:// from Clipboard',
              icon: Icons.content_paste_go_rounded,
              onPressed: _prefillFromClipboard,
            ),
          ],
        ),
        _section(
          'UDP Server (Hysteria 2)',
          Icons.wifi_tethering_rounded,
          caption: 'QUIC/UDP tunnel — already obfuscated end to end, so no '
              'payload / bug-host front is used.',
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: SenseiField(
                    label: 'Address',
                    controller: _addressController,
                    hint: 'server.com / 1.2.3.4',
                  ),
                ),
                const SizedBox(width: SenseiTokens.gapMd),
                Expanded(
                  flex: 1,
                  child: SenseiField(
                    label: 'Port',
                    controller: _portController,
                    hint: '443',
                    number: true,
                  ),
                ),
              ],
            ),
            SenseiField(
              label: 'Auth Token',
              controller: _hyperAuthController,
              hint: 'server password — empty if the server has none',
              mono: true,
            ),
            SenseiField(
              label: 'SNI (optional)',
              controller: _sniController,
              hint: 'sni.host.com — empty = accept any certificate',
            ),
          ],
        ),
      ],
    );
  }

  // ---- WireGuard -------------------------------------------------------------

  Widget _wireguardSection() {
    final t = context.tokens;
    final hasConf = _wgController.text.trim().isNotEmpty;
    final ep = _wgEndpoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'WireGuard Config',
          Icons.shield_moon_rounded,
          caption: 'Paste the [Interface] + [Peer] config your provider gave '
              'you, or pick a .conf / .wg file. WireGuard rides raw UDP.',
          children: [
            SenseiCard(
              onTap: _pickWgFile,
              radius: SenseiTokens.radiusMd,
              child: Column(
                children: [
                  Icon(hasConf ? Icons.description_rounded : Icons.upload_file_rounded,
                      color: t.accent, size: 30),
                  const SizedBox(height: SenseiTokens.gapSm),
                  Text(
                    hasConf
                        ? (_wgFileName.isNotEmpty ? _wgFileName : 'Config loaded')
                        : 'Tap to pick a .conf / .wg file',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: t.text, fontSize: 13.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasConf ? 'Tap to replace' : 'Pasting the contents below works too',
                    style: TextStyle(color: t.textMuted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            SenseiField(
              label: 'Config Contents',
              controller: _wgController,
              hint: '[Interface]\nPrivateKey = …\n\n[Peer]\nPublicKey = …\n'
                  'Endpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0',
              maxLines: 8,
              mono: true,
            ),
            if (ep != null)
              Padding(
                padding: const EdgeInsets.only(top: SenseiTokens.gapSm),
                child: Text(
                  'Endpoint: ${ep.group(1)}:${ep.group(2)} · UDP',
                  style: TextStyle(
                      color: t.accent, fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ---- Psiphon ---------------------------------------------------------------

  Widget _psiphonSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'Psiphon',
          Icons.travel_explore_rounded,
          caption: 'Public circumvention network — no server address or '
              'credentials needed. Traffic exits in the region you pick.',
          children: [
            SenseiDropdown<String>(
              label: 'Exit Region',
              value: _psiphonRegion,
              items: _psiphonRegionNames.keys.toList(),
              itemLabel: (r) => '$r — ${_psiphonRegionNames[r]}',
              onChanged: (v) => setState(() => _psiphonRegion = v),
            ),
            const SenseiNotice(
              message:
                  'Psiphon is best-effort: it bridges through the public psiphon '
                  'fronts, so speeds vary. Use VLESS/SSH for a dedicated relay.',
            ),
          ],
        ),
      ],
    );
  }

  // ===========================================================================
  // Reusable pieces
  // ===========================================================================

  /// Titled, padded group used to replace the old `_card` helper.
  Widget _section(
    String title,
    IconData icon, {
    String? caption,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SenseiTokens.gapLg),
      child: SenseiSection(
        title: title,
        caption: caption,
        icon: icon,
        divided: false,
        padding: const EdgeInsets.all(SenseiTokens.gap),
        children: children,
      ),
    );
  }

  /// Common DPI-bypass request templates. The engine expands the `[...]`
  /// placeholders (`PayloadInjector.renderPayload`) at connect time.
  static const List<(String, String)> _payloadPresets = [
    (
      'CONNECT',
      '[method] [host_port] [protocol][crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]',
    ),
    (
      'GET',
      'GET / [protocol][crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]',
    ),
    (
      'WebSocket',
      'GET / [protocol][crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
    ),
    (
      'Split host',
      '[method] [host_port] [protocol][crlf]Host: [host][crlf][crlf][method] [host_port] [protocol][crlf][crlf]',
    ),
    (
      'Online-Host',
      '[method] [host_port] [protocol][crlf]X-Online-Host: [host][crlf]X-Forward-Host: [host][crlf][crlf]',
    ),
  ];

  Widget _payloadPresetBar() {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SenseiTokens.gapSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Templates', style: t.overline),
          const SizedBox(height: SenseiTokens.gapSm),
          Wrap(
            spacing: SenseiTokens.gapSm,
            runSpacing: SenseiTokens.gapSm,
            children: [
              for (final (label, template) in _payloadPresets)
                GestureDetector(
                  onTap: () => setState(() => _payloadController.text = template),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: SenseiTokens.gapMd, vertical: 7),
                    decoration: BoxDecoration(
                      color: t.surfaceAltFill,
                      borderRadius: SenseiTokens.brPill,
                      border: Border.all(color: t.border),
                    ),
                    child: Text(label,
                        style: TextStyle(
                            color: t.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
