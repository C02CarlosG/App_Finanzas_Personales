import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Sesión autenticada. El token JWT solo se guarda en almacenamiento seguro.
class Session {
  const Session({
    required this.token,
    required this.userId,
    required this.email,
    required this.name,
  });

  final String token;
  final String userId;
  final String email;
  final String name;

  Map<String, dynamic> toJson() => {'token': token, 'user_id': userId, 'email': email, 'name': name};

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        token: json['token'] as String,
        userId: json['user_id'] as String,
        email: json['email'] as String,
        name: json['name'] as String,
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
