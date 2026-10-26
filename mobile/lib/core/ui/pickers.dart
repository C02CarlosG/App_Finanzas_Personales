import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_providers.dart';
import '../format/dates.dart';

/// Renglón de fecha: muestra la fecha elegida y abre el selector (en español) al tocarlo.
/// Con [clearable] permite quitar la fecha (plazos opcionales).
class DateTile extends StatelessWidget {
  const DateTile({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = false,
    this.hint = 'Sin fecha',
    this.firstDate,
  });

  final String label;
  final String? value; // YYYY-MM-DD
  final ValueChanged<String?> onChanged;
  final bool clearable;
  final String hint;
  final DateTime? firstDate;

  Future<void> _pick(BuildContext context) async {
    final initial = value == null ? DateTime.now() : parseIsoDate(value!);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate ?? DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) onChanged(isoDate(picked));
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.event),
      title: Text(label),
      subtitle: Text(value == null ? hint : formatDate(value!)),
      trailing: clearable && value != null
          ? IconButton(icon: const Icon(Icons.close), tooltip: 'Quitar fecha', onPressed: () => onChanged(null))
          : null,
      onTap: () => _pick(context),
    );
  }
}

/// Selector de cuenta con su saldo. Con [allowNone] agrega "Sin cuenta" (selección opcional); si no,
/// es obligatorio y con una sola cuenta viene preseleccionada.
class AccountDropdown extends ConsumerWidget {
  const AccountDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Cuenta',
    this.allowNone = false,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final bool allowNone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final selected = accounts.any((a) => a.id == value) ? value : (!allowNone && accounts.length == 1 ? accounts.first.id : null);
    // Con una sola cuenta se preselecciona: el padre debe enterarse para poder guardarla.
    if (selected != value && selected != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onChanged(selected));
    }
    return DropdownButtonFormField<String?>(
      key: ValueKey('cuenta-${accounts.length}-$selected'),
      isExpanded: true,
      initialValue: selected,
      decoration: InputDecoration(labelText: label),
      items: [
        if (allowNone) const DropdownMenuItem<String?>(value: null, child: Text('Sin cuenta')),
        for (final a in accounts)
          DropdownMenuItem<String?>(value: a.id, child: Text('${a.name} · ${a.balance.format()}', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: onChanged,
      validator: (v) => (!allowNone && v == null) ? 'Elige una cuenta' : null,
    );
  }
}

/// Mensaje de "aún no hay nada" con una acción; se desplaza si no cabe (texto grande, pantallas bajas).
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.actionLabel, this.onAction});

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                if (actionLabel != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(onPressed: onAction, icon: const Icon(Icons.add), label: Text(actionLabel!)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fondo de un formulario en hoja inferior: sube con el teclado y se desplaza si no cabe.
class SheetBody extends StatelessWidget {
  const SheetBody({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      ),
    );
  }
}
