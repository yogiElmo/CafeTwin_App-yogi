import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/auth_service.dart';

/// Admin-only screen for turning multi-factor authentication on or off
/// for the CALLING admin's own account (there is no "set up MFA for
/// someone else" -- see the "TOTP MULTI-FACTOR AUTHENTICATION" section of
/// cafetwin_backend_devops/server.js).
///
/// MFA here is standard TOTP (RFC 6238): Google Authenticator, Microsoft
/// Authenticator, Authy, 1Password, etc. all work identically, since the
/// backend never talks to any of those apps or companies -- it just hands
/// this screen a shared secret + an otpauth:// URI, which is rendered as
/// a QR code entirely on-device via [QrImageView].
///
/// Only reachable from [HomeShell] when [AuthService.isAdmin] is true --
/// the backend enforces the same rule independently (`requireRole
/// ('admin')` on every /auth/totp/* route), so this screen is a
/// convenience, not the real gate.
class MfaSetupScreen extends StatefulWidget {
  const MfaSetupScreen({super.key});

  @override
  State<MfaSetupScreen> createState() => _MfaSetupScreenState();
}

/// Which step of the flow is on screen right now.
enum _Step {
  loading,
  off, // MFA is off; showing the "Set up MFA" entry point.
  settingUp, // Secret generated; showing the QR code + code field.
  showRecoveryCodes, // Just enabled (or just regenerated); showing codes once.
  on, // MFA is on; showing "Turn off" / "Regenerate codes".
}

class _MfaSetupScreenState extends State<MfaSetupScreen> {
  static const Color _amber = Color(0xFFD9A441);
  static const Color _surface = Color(0xFF26221E);
  static const Color _border = Color(0xFF3A332C);

  _Step _step = _Step.loading;
  String? _error;
  bool _busy = false;

  // Set by setupTotp(), consumed by enableTotp().
  String? _pendingSecret;
  String? _pendingOtpauthUrl;
  final TextEditingController _codeController = TextEditingController();

  // Shown once after enable/regenerate.
  List<String> _recoveryCodes = const <String>[];

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _step = _Step.loading;
      _error = null;
    });
    final bool? enabled = await AuthService.getTotpStatus();
    if (!mounted) return;
    setState(() {
      _step = enabled == true ? _Step.on : _Step.off;
      if (enabled == null) {
        _error = 'Could not load MFA status. Check the backend connection.';
      }
    });
  }

  Future<void> _startSetup() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final TotpSetup result = await AuthService.setupTotp();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.error != null) {
        _error = result.error;
        return;
      }
      _pendingSecret = result.secret;
      _pendingOtpauthUrl = result.otpauthUrl;
      _step = _Step.settingUp;
    });
  }

  Future<void> _confirmEnable() async {
    final String code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the 6-digit code shown in your authenticator app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final TotpEnableResult result = await AuthService.enableTotp(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.error != null) {
        _error = result.error;
        return;
      }
      _codeController.clear();
      _pendingSecret = null;
      _pendingOtpauthUrl = null;
      _recoveryCodes = result.recoveryCodes ?? const <String>[];
      _step = _Step.showRecoveryCodes;
    });
  }

  /// Shared by "Turn off MFA" and "Regenerate recovery codes" -- both
  /// need the account's current password + PIN, not a TOTP code (see
  /// the comment on POST /auth/totp/disable in server.js).
  Future<Map<String, String>?> _promptForPasswordAndPin(String title) {
    final TextEditingController password = TextEditingController();
    final TextEditingController pin = TextEditingController();
    return showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Authentication PIN'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(<String, String>{
              'password': password.text,
              'pin': pin.text.trim(),
            }),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Future<void> _disable() async {
    final Map<String, String>? credentials =
        await _promptForPasswordAndPin('Turn off MFA');
    if (credentials == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final String? error = await AuthService.disableTotp(
      password: credentials['password']!,
      pin: credentials['pin']!,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await _refreshStatus();
  }

  Future<void> _regenerateCodes() async {
    final Map<String, String>? credentials =
        await _promptForPasswordAndPin('Regenerate recovery codes');
    if (credentials == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final TotpEnableResult result = await AuthService.regenerateRecoveryCodes(
      password: credentials['password']!,
      pin: credentials['pin']!,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.error != null) {
        _error = result.error;
        return;
      }
      _recoveryCodes = result.recoveryCodes ?? const <String>[];
      _step = _Step.showRecoveryCodes;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Factor Authentication')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildStep(context),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    switch (_step) {
      case _Step.loading:
        return const Padding(
          padding: EdgeInsets.only(top: 40),
          child: Center(child: CircularProgressIndicator()),
        );
      case _Step.off:
        return _buildOff();
      case _Step.settingUp:
        return _buildSettingUp();
      case _Step.showRecoveryCodes:
        return _buildRecoveryCodes();
      case _Step.on:
        return _buildOn();
    }
  }

  Widget _buildOff() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Add a second step to logging in',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Once enabled, logging in to this account needs a 6-digit code '
          'from an authenticator app (Google Authenticator, Microsoft '
          'Authenticator, Authy, or anything else that speaks the same '
          'standard) in addition to your password and PIN.',
        ),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          onPressed: _busy ? null : _startSetup,
          icon: const Icon(Icons.qr_code),
          label: Text(_busy ? 'Starting…' : 'Set up MFA'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _amber,
            foregroundColor: const Color(0xFF1E1B18),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingUp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '1. Scan this with your authenticator app',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        if (_pendingOtpauthUrl != null)
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: _pendingOtpauthUrl!,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          "Can't scan? Enter this code manually:",
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 4),
        SelectableText(
          _pendingSecret ?? '',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '2. Enter the 6-digit code it shows',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Authentication code',
            filled: true,
            fillColor: _surface,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border),
            ),
          ),
          onSubmitted: (_) => _confirmEnable(),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _busy ? null : _confirmEnable,
          style: ElevatedButton.styleFrom(
            backgroundColor: _amber,
            foregroundColor: const Color(0xFF1E1B18),
            minimumSize: const Size.fromHeight(46),
          ),
          child: Text(_busy ? 'Verifying…' : 'Enable MFA'),
        ),
      ],
    );
  }

  Widget _buildRecoveryCodes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Save your recovery codes',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          "Each code works once, in place of a code from your authenticator "
          'app, if you ever lose access to it. They will not be shown '
          'again after you leave this screen.',
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _border),
          ),
          child: SelectableText(
            _recoveryCodes.join('\n'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.6),
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _refreshStatus,
          style: ElevatedButton.styleFrom(
            backgroundColor: _amber,
            foregroundColor: const Color(0xFF1E1B18),
            minimumSize: const Size.fromHeight(46),
          ),
          child: const Text("I've saved these codes"),
        ),
      ],
    );
  }

  Widget _buildOn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.verified_user, color: Colors.green),
            const SizedBox(width: 8),
            const Text(
              'MFA is on for this account',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Logging in needs a code from your authenticator app in '
          'addition to your password and PIN.',
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _busy ? null : _regenerateCodes,
          icon: const Icon(Icons.refresh),
          label: const Text('Regenerate recovery codes'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _disable,
          icon: Icon(Icons.no_encryption_gmailerrorred, color: Theme.of(context).colorScheme.error),
          label: Text(
            'Turn off MFA',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    );
  }
}
