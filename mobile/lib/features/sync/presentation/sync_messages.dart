/// Explica en español un error de sincronización guardado en la outbox (docs/sync.md §4).
String syncErrorMessage(String? lastError, {required bool blocked}) {
  final code = (lastError ?? '').split(':').first.trim();
  switch (code) {
    case 'invalid_reference':
      return 'Falta la cuenta o la categoría de este movimiento (quizá se eliminó en otro dispositivo). '
          'Edítalo y elige otra, o elimínalo.';
    case 'validation_error':
      return 'El servidor rechazó estos datos. Revísalos y vuelve a guardar, o elimínalo.';
    case 'immutable_field':
    case 'category_kind_mismatch':
      return 'Este cambio no es válido para el servidor. Elimínalo y vuelve a crearlo.';
    case 'invalid_id':
      return 'Este registro no se puede sincronizar. Elimínalo y vuelve a crearlo.';
    case 'conflict':
      return 'Hubo un conflicto temporal; se reintentará solo.';
  }
  return blocked ? 'El servidor rechazó este cambio.' : 'No se pudo enviar; se reintentará.';
}
