/// A single admin/staff login account, as returned by
/// `GET /admin/users` on the backend. Never carries a password or PIN --
/// the backend only ever returns the hash-free summary fields below.
class AdminAccount {
  AdminAccount({
    required this.username,
    required this.role,
    required this.createdAt,
  });

  factory AdminAccount.fromJson(Map<String, dynamic> json) {
    return AdminAccount(
      username: json['username'] as String,
      role: json['role'] as String,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// Login username.
  final String username;

  /// `'admin'` or `'staff'`.
  final String role;

  /// When the account was created.
  final DateTime createdAt;
}
