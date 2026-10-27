import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/api_messages.dart';

/// Campo de un [ActionDialog]. El validador recibe el texto del campo y el de todos los campos (en orden),
/// para comparar «nueva contraseña» con su confirmación.
class ActionField {
  const ActionField({
    required this.key,
    required this.label,
    this.initial = '',
    this.obscure = false,
    this.keyboard,
    this.validator,
  });

  final Key key;
  final String label;
  final String initial;
  final bool obscure;
  final TextInputType? keyboard;
  final String? Function(String value, List<String> all)? validator;
}

/// Diálogo con formulario para las acciones del perfil: valida, ejecuta [onSubmit] y muestra el error del
/// servidor (contraseña incorrecta, sin conexión, demasiados intentos…) sin cerrarse. Con éxito devuelve `true`.
class ActionDialog extends StatefulWidget {
  const ActionDialog({
    super.key,
    required this.title,
    required this.submitLabel,
    required this.submitKey,
    required this.onSubmit,
    this.fields = const [],
    this.intro,
    this.destructive = false,
  });

  final String title;
  final String? intro;
  final String submitLabel;
  final Key submitKey;
  final List<ActionField> fields;
  final bool destructive;
  final Future<void> Function(List<String> values) onSubmit;

  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controllers = [for (final f in widget.fields) TextEditingController(text: f.initial)];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _values => [for (final c in _controllers) c.text];

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_values);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = profileErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true, // con letra grande o teclado abierto el contenido se desplaza en vez de desbordarse
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.intro != null) ...[Text(widget.intro!), const SizedBox(height: 12)],
            for (var i = 0; i < widget.fields.length; i++) ...[
              TextFormField(
                key: widget.fields[i].key,
                controller: _controllers[i],
                decoration: InputDecoration(labelText: widget.fields[i].label),
                obscureText: widget.fields[i].obscure,
                keyboardType: widget.fields[i].keyboard,
                enabled: !_busy,
                textInputAction: i == widget.fields.length - 1 ? TextInputAction.done : TextInputAction.next,
                onFieldSubmitted: i == widget.fields.length - 1 ? (_) => _submit() : null,
                validator: (v) => widget.fields[i].validator?.call(v ?? '', _values),
              ),
              const SizedBox(height: 8),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error!, key: const Key('error-dialogo'), style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancelar-dialogo'),
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: widget.submitKey,
          style: widget.destructive
              ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.submitLabel),
        ),
      ],
    );
  }
}
