import 'models.dart';

/// A pairing the television has just opened: the private half it polls with,
/// and the short half it puts on screen.
class DevicePairing {
  /// Secret handle. Never displayed — it is the only thing that can collect the
  /// session once a phone approves.
  final String deviceCode;

  /// Eight characters from an unambiguous alphabet, shown on the TV and encoded
  /// in the QR.
  final String userCode;

  final Duration expiresIn;
  final Duration pollInterval;

  const DevicePairing({
    required this.deviceCode,
    required this.userCode,
    required this.expiresIn,
    required this.pollInterval,
  });

  factory DevicePairing.fromJson(Map<String, dynamic> json) {
    return DevicePairing(
      deviceCode: json['device_code'] as String? ?? '',
      userCode: json['user_code'] as String? ?? '',
      expiresIn: Duration(seconds: (json['expires_in'] as num? ?? 300).toInt()),
      pollInterval: Duration(seconds: (json['interval'] as num? ?? 2).toInt()),
    );
  }

  /// The code split for display. Eight unbroken characters are read wrong from
  /// a couch; two groups of four are not.
  String get formattedUserCode {
    if (userCode.length != 8) return userCode;
    return '${userCode.substring(0, 4)}-${userCode.substring(4)}';
  }
}

enum DevicePairingState { pending, approved, expired }

/// One poll's answer. [token] and [user] are set only once, on the poll that
/// finds the pairing approved — collecting the session consumes it server-side.
class DevicePairingStatus {
  final DevicePairingState state;
  final String? token;
  final User? user;

  const DevicePairingStatus({required this.state, this.token, this.user});

  factory DevicePairingStatus.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    return DevicePairingStatus(
      state: switch (json['status'] as String?) {
        'approved' => DevicePairingState.approved,
        'expired' => DevicePairingState.expired,
        _ => DevicePairingState.pending,
      },
      token: json['token'] as String?,
      user: rawUser is Map<String, dynamic> ? User.fromJson(rawUser) : null,
    );
  }

  bool get isApproved =>
      state == DevicePairingState.approved &&
      token != null &&
      token!.isNotEmpty;
}

/// What the approving phone is told about the screen that is asking, so the
/// confirmation is a decision rather than a blind yes.
class DevicePairingRequest {
  final String userCode;
  final String deviceName;
  final Duration expiresIn;

  const DevicePairingRequest({
    required this.userCode,
    required this.deviceName,
    required this.expiresIn,
  });

  factory DevicePairingRequest.fromJson(Map<String, dynamic> json) {
    return DevicePairingRequest(
      userCode: json['user_code'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? 'Téléviseur',
      expiresIn: Duration(seconds: (json['expires_in'] as num? ?? 0).toInt()),
    );
  }
}

/// A session minted for another device, delivered to it by this one.
class DeviceSession {
  final String token;
  final User user;

  const DeviceSession({required this.token, required this.user});

  factory DeviceSession.fromJson(Map<String, dynamic> json) {
    return DeviceSession(
      token: json['token'] as String,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}
