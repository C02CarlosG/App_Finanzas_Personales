import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/app_database.dart';
import '../data/categories_repository.dart';

Color categoryColorOf(String? hex, Color fallback) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return fallback;
  return Color(int.parse('FF${hex.substring(1)}', radix: 16));
}

/// Color para mostrar una categoría: el suyo, o uno estable de la paleta según su nombre.
/// Las categorías que siembra el servidor no traen color; con gris claro el icono blanco no se vería.
Color categoryDisplayColor(String? hex, String? name) {
  final valid = hex != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex);
  if (valid) return categoryColorOf(hex, Colors.grey);
  var h = 0;
  for (final unit in (name ?? '').codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return categoryColorOf(categoryColors[h % categoryColors.length], Colors.grey);
}

/// Crea (si [category] es `null`) o edita una categoría. Las del sistema solo cambian de color.
Future<void> showCategoryEditor(BuildContext context, {required String kind, CategoryRow? category}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CategoryEditorSheet(kind: kind, category: category),
  );
}

class CategoryEditorSheet extends ConsumerStatefulWidget {
  const CategoryEditorSheet({super.key, required this.kind, this.category});

  final String kind;
  final CategoryRow? category;

  @override
  ConsumerState<CategoryEditorSheet> createState() => _CategoryEditorSheetState();
}

class _CategoryEditorSheetState extends ConsumerState<CategoryEditorSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.category?.name ?? '');
  late String? _color = widget.category?.color;
  String? _error;
  bool _busy = false;

  bool get _editing => widget.category != null;
  bool get _system => widget.category?.isSystem ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(categoriesRepositoryProvider);
    try {
      if (_editing) {
        await repo.update(widget.category!.id, name: _name.text, color: _color);
      } else {
        await repo.create(kind: widget.kind, name: _name.text, color: _color);
      }
      if (mounted) Navigator.pop(context);
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _error = null);
    try {
      await ref.read(categoriesRepositoryProvider).delete(widget.category!.id);
      if (mounted) Navigator.pop(context);
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_editing ? 'Editar categoría' : (widget.kind == 'income' ? 'Nueva categoría de ingresos' : 'Nueva categoría de gastos'),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              key: const Key('campo-nombre-categoria'),
              controller: _name,
              enabled: !_system,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: 'Nombre',
                helperText: _system ? 'Categoría del sistema: solo puedes cambiar su color' : null,
              ),
            ),
            const SizedBox(height: 8),
            Text('Color', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final hex in categoryColors)
                Semantics(
                  button: true,
                  selected: _color == hex,
                  label: 'Color ${categoryColors.indexOf(hex) + 1} de ${categoryColors.length}',
                  child: InkResponse(
                    key: Key('color-$hex'),
                    onTap: () => setState(() => _color = hex),
                    radius: 24,
                    child: SizedBox(
                      width: 44, // objetivo táctil mínimo recomendado
                      height: 44,
                      child: Center(
                        child: CircleAvatar(
                          radius: 17,
                          backgroundColor: categoryColorOf(hex, theme.colorScheme.primary),
                          child: _color == hex ? const Icon(Icons.check, size: 20, color: Colors.white) : null,
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, key: const Key('error-categoria'), style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            Row(children: [
              if (_editing && !_system)
                TextButton.icon(
                  key: const Key('eliminar-categoria'),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Eliminar'),
                ),
              const Spacer(),
              FilledButton(key: const Key('guardar-categoria'), onPressed: _busy ? null : _save, child: const Text('Guardar')),
            ]),
          ],
        ),
      ),
    );
  }
}
