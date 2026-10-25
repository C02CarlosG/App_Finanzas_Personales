import 'package:flutter/material.dart';

/// Para el `trailing` de un `ListTile` con un importe: lo limita a menos de la mitad del ancho y lo reduce
/// si hace falta. Con texto del sistema muy grande el importe no cabe y `ListTile` falla (en depuración
/// con una aserción; en producción, con el diseño roto).
class FitTrailing extends StatelessWidget {
  const FitTrailing({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.45),
      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: child),
    );
  }
}
