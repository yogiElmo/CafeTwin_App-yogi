import 'package:flutter/material.dart';

import '../models/admin_account.dart';
import '../services/auth_service.dart';

/// Admin-only screen for managing login accounts: lists existing
/// admin/staff accounts (via `GET /admin/users`) and creates new ones
/// (via `POST /admin/users`). Only reachable from [HomeShell] when
/// [AuthService.isAdmin] is true -- the backend enforces the same rule
/// independently, so this screen is a convenience, not the real gate.
class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  static const Color _amber = Color(0xFFD9A441);
  static const Color _surface = Color(0xFF26221E);
  static const Color _border = Color(0xFF3A332C);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();
  String _newRole = 'staff';

  List<AdminAccount>? _users;
  bool _loadingUsers = true;
  bool _creating = false;
  String? _listError;
  String? _formError;
  String? _formSuccess;

  /// Username currently being deleted (disables that row's button and
  /// shows a spinner in place of the delete icon), or null when idle.
  String? _deletingUsername;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loadingUsers = true;
      _listError = null;
    });
    final List<AdminAccount>? users = await AuthService.listUsers();
    if (!mounted) return;
    setState(() {
      _loadingUsers = false;
      if (users == null) {
        _listError = 'Could not load accounts. Check the backend connection.';
      } else {
        _users = users;
      }
    });
  }

  Future<void> _createUser() async {
    final String username = _usernameController.text.trim();
    final String password = _passwordController.text;
    final String pin = _pinController.text.trim();

    if (username.isEmpty || password.isEmpty || pin.isEmpty) {
      setState(() {
        _formError = 'Please fill in username, password and PIN.';
        _formSuccess = null;
      });
      return;
    }

    setState(() {
      _creating = true;
      _formError = null;
      _formSuccess = null;
    });

    final String? error = await AuthService.createUser(
      username: username,
      password: password,
      pin: pin,
      role: _newRole,
    );

    if (!mounted) return;
    setState(() {
      _creating = false;
      if (error != null) {
        _formError = error;
      } else {
        _formSuccess = 'Account "$username" created.';
        _usernameController.clear();
        _passwordController.clear();
        _pinController.clear();
        _newRole = 'staff';
      }
    });

    if (error == null) {
      await _refresh();
    }
  }

  Future<void> _confirmAndDelete(AdminAccount account) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Delete account?'),
        content: Text(
          'This permanently deletes the login account "${account.username}". '
          'This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _deletingUsername = account.username;
      _formError = null;
      _formSuccess = null;
    });

    final String? error = await AuthService.deleteUser(account.username);
    if (!mounted) return;

    setState(() {
      _deletingUsername = null;
      if (error != null) {
        _formError = error;
      } else {
        _formSuccess = 'Account "${account.username}" deleted.';
      }
    });

    if (error == null) {
      await _refresh();
    }
  }

  InputDecoration _fieldDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20, color: _amber),
      filled: true,
      fillColor: _surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _amber),
      ),
    );
  }

  Widget _userRow(AdminAccount account) {
    final bool isAdmin = account.role == 'admin';
    final bool isSelf = account.username == AuthService.currentUsername;
    final bool deleting = _deletingUsername == account.username;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            isAdmin ? Icons.admin_panel_settings : Icons.person_outline,
            size: 18,
            color: isAdmin ? _amber : Colors.grey,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isSelf ? '${account.username} (you)' : account.username,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: isAdmin
                  ? _amber.withValues(alpha: 0.18)
                  : Colors.grey.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              account.role.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: isAdmin ? _amber : Colors.grey.shade400,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (deleting)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              color: Colors.grey,
              tooltip: isSelf
                  ? "You can't delete the account you're logged in as"
                  : 'Delete account',
              onPressed: isSelf || _deletingUsername != null
                  ? null
                  : () => _confirmAndDelete(account),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color dim =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

    return Scaffold(
      appBar: AppBar(title: const Text('Manage Users')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: _amber.withValues(alpha: 0.30)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'EXISTING ACCOUNTS',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _amber,
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_loadingUsers)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                            )
                          else if (_listError != null)
                            Text(
                              _listError!,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            )
                          else if (_users == null || _users!.isEmpty)
                            Text(
                              'No accounts found.',
                              style: TextStyle(fontSize: 13, color: dim),
                            )
                          else
                            for (final AdminAccount u in _users!) _userRow(u),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: _amber.withValues(alpha: 0.30)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'ADD NEW ACCOUNT',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _amber,
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _usernameController,
                            decoration:
                                _fieldDecoration('Username', Icons.person),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _passwordController,
                            obscureText: true,
                            decoration:
                                _fieldDecoration('Password', Icons.lock),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _pinController,
                            obscureText: true,
                            keyboardType: TextInputType.number,
                            decoration: _fieldDecoration(
                                'PIN', Icons.pin_outlined),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              const Text(
                                'Role',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _newRole,
                                  dropdownColor: _surface,
                                  decoration: InputDecoration(
                                    filled: true,
                                    fillColor: _surface,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 4),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide:
                                          const BorderSide(color: _border),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide:
                                          const BorderSide(color: _amber),
                                    ),
                                  ),
                                  items: const <DropdownMenuItem<String>>[
                                    DropdownMenuItem<String>(
                                      value: 'staff',
                                      child: Text('Staff'),
                                    ),
                                    DropdownMenuItem<String>(
                                      value: 'admin',
                                      child: Text('Admin'),
                                    ),
                                  ],
                                  onChanged: (String? value) {
                                    if (value != null) {
                                      setState(() => _newRole = value);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          if (_formError != null) ...<Widget>[
                            const SizedBox(height: 12),
                            Text(
                              _formError!,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          if (_formSuccess != null) ...<Widget>[
                            const SizedBox(height: 12),
                            Text(
                              _formSuccess!,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.lightGreen,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: _creating ? null : _createUser,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _amber,
                              foregroundColor: const Color(0xFF1E1B18),
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: _creating
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF1E1B18),
                                    ),
                                  )
                                : const Text('Create Account'),
                          ),
                        ],
                      ),
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
