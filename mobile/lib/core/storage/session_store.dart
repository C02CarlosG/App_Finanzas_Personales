import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Sesión autenticada. El token JWT solo se guarda en almacenamiento seguro.
class Session {
  const Session({
    required this.token,
    required this.userId,
    required this.email,
    required this.name,
    this.plan = 'free',
  });

  final String token;
  final String userId;
  final String email;
  final String name;

  /// Plan de suscripción (`free` / `premium`) tal como lo informó el servidor por última vez.
  final String plan;

  Session copyWith({String? token, String? email, String? name, String? plan}) => Session(
        token: token ?? this.token,
        userId: userId,
        email: email ?? this.email,
        name: name ?? this.name,
        plan: plan ?? this.plan,
      );

  Map<String, dynamic> toJson() => {'token': token, 'user_id': userId, 'email': email, 'name': name, 'plan': plan};

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        token: json['token'] as String,
        userId: json['user_id'] as String,
        email: json['email'] as String,
        name: json['name'] as String,
        plan: (json['plan'] as String?) ?? 'free', // sesiones guardadas por versiones anteriores no lo traen
      );
}

abstract class SessionStore {
  Future<Session?> read();
  Future<void> write(Session session);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'session';
  final FlutterSecureStorage _storage;

  @override
  Future<Session?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      await clear(); // dato corrupto: se descarta
      return null;
    }
  }

  @override
  Future<void> write(Session session) => _storage.write(key: _key, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Para pruebas y modo demo.
class MemorySessionStore implements SessionStore {
  MemorySessionStore([this._session]);
  Session? _session;

  @override
  Future<Session?> read() async => _session;

  @override
  Future<void> write(Session session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
