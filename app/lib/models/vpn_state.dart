import 'package:flutter/material.dart';

enum VpnConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error
}

enum ErrorCategory {
  none,
  server,
  network,
  auth,
  config,
  unknown,
}

extension ErrorCategoryX on ErrorCategory {
  String get label {
    switch (this) {
      case ErrorCategory.server:
        return 'Server issue';
      case ErrorCategory.network:
        return 'Network issue';
      case ErrorCategory.auth:
        return 'Authentication failed';
      case ErrorCategory.config:
        return 'Config error';
      case ErrorCategory.unknown:
        return 'Unknown error';
      case ErrorCategory.none:
        return '';
    }
  }

  IconData get icon {
    switch (this) {
      case ErrorCategory.server:
        return Icons.dns_outlined;
      case ErrorCategory.network:
        return Icons.wifi_off_rounded;
      case ErrorCategory.auth:
        return Icons.lock_outline_rounded;
      case ErrorCategory.config:
        return Icons.settings_outlined;
      case ErrorCategory.unknown:
      case ErrorCategory.none:
        return Icons.error_outline_rounded;
    }
  }
}

class VpnState extends ChangeNotifier {
  VpnConnectionState _connectionState = VpnConnectionState.disconnected;
  String _connectedServerName = '';
  String _errorMessage = '';
  ErrorCategory _errorCategory = ErrorCategory.none;
  Duration _connectionDuration = Duration.zero;
  int _downloadSpeed = 0;
  int _uploadSpeed = 0;
  int _totalDownload = 0;
  int _totalUpload = 0;

  VpnConnectionState get connectionState => _connectionState;
  String get connectedServerName => _connectedServerName;
  String get errorMessage => _errorMessage;
  ErrorCategory get errorCategory => _errorCategory;
  Duration get connectionDuration => _connectionDuration;
  int get downloadSpeed => _downloadSpeed;
  int get uploadSpeed => _uploadSpeed;
  int get totalDownload => _totalDownload;
  int get totalUpload => _totalUpload;

  bool get isConnected => _connectionState == VpnConnectionState.connected;
  bool get isConnecting => _connectionState == VpnConnectionState.connecting;
  bool get isDisconnected =>
      _connectionState == VpnConnectionState.disconnected;
  bool get hasError => _errorMessage.isNotEmpty;

  String get errorCategoryLabel => _errorCategory.label;

  IconData get errorCategoryIcon => _errorCategory.icon;

  void setConnecting(String serverName) {
    _connectionState = VpnConnectionState.connecting;
    _connectedServerName = serverName;
    _errorMessage = '';
    notifyListeners();
  }

  void setConnected() {
    _connectionState = VpnConnectionState.connected;
    _errorMessage = '';
    notifyListeners();
  }

  void setDisconnected() {
    _connectionState = VpnConnectionState.disconnected;
    _connectedServerName = '';
    _downloadSpeed = 0;
    _uploadSpeed = 0;
    notifyListeners();
  }

  void setError(String message, {ErrorCategory category = ErrorCategory.unknown}) {
    _connectionState = VpnConnectionState.error;
    _errorMessage = message;
    _errorCategory = category;
    notifyListeners();
  }

  void setDisconnecting() {
    _connectionState = VpnConnectionState.disconnecting;
    notifyListeners();
  }

  void updateSpeed(int downSpeed, int upSpeed, int totalDown, int totalUp) {
    _downloadSpeed = downSpeed;
    _uploadSpeed = upSpeed;
    _totalDownload = totalDown;
    _totalUpload = totalUp;
    notifyListeners();
  }

  void updateDuration(Duration duration) {
    _connectionDuration = duration;
    notifyListeners();
  }

  String get connectionStateText {
    switch (_connectionState) {
      case VpnConnectionState.disconnected:
        return 'Disconnected';
      case VpnConnectionState.connecting:
        return 'Connecting...';
      case VpnConnectionState.connected:
        return 'Connected';
      case VpnConnectionState.disconnecting:
        return 'Disconnecting...';
      case VpnConnectionState.error:
        return 'Error: $_errorMessage';
    }
  }
}
