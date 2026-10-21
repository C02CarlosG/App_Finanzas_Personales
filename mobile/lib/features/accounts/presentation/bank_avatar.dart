import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Rutas de `assets/banks/` incluidas en la app (para saber qué logos hay sin provocar errores de carga).
final bankLogoAssetsProvider = FutureProvider<Set<String>>((ref) async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  return manifest.listAssets().where((a) => a.startsWith('assets/banks/') && a.endsWith('.png')).toSet();
});

/// Color de marca aproximado por `logo_key` (clave del catálogo del servidor).
const _brandColors = <String, Color>{
  'bbva': Color(0xFF004481),
  'santander': Color(0xFFEC0000),
  'banamex': Color(0xFF0066B3),
  'banorte': Color(0xFFEB0029),
  'hsbc': Color(0xFFDB0011),
  'scotiabank': Color(0xFFEC111A),
  'inbursa': Color(0xFF0B3C7D),
  'azteca': Color(0xFF00A859),
  'bancoppel': Color(0xFFF2B600),
  'afirme': Color(0xFF00843D),
  'banregio': Color(0xFFF26722),
  'nu': Color(0xFF820AD1),
  'hey': Color(0xFF00A99D),
  'mercadopago': Color(0xFF009EE3),
  'klar': Color(0xFF222222),
  'spin': Color(0xFFFF6900),
};

Color bankColor(String? logoKey, {Color fallback = const Color(0xFF607D8B)}) => _brandColors[logoKey] ?? fallback;

/// `BBVA México` → `BBVA`; `Santander` → `Sa`; `Nu México` → `Nu`.
String bankInitials(String name) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  if (first.length <= 4 && first == first.toUpperCase()) return first;
  return first.length <= 2 ? first : '${first[0].toUpperCase()}${first[1].toLowerCase()}';
}

/// Logo del banco: usa `assets/banks/<logo_key>.png` si existe; si no, un avatar con iniciales y color.
class BankAvatar extends ConsumerWidget {
  const BankAvatar({super.key, required this.name, this.logoKey, this.size = 44});

  final String name;
  final String? logoKey;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(bankLogoAssetsProvider).value ?? const <String>{};
    final path = 'assets/banks/$logoKey.png';
    if (logoKey != null && assets.contains(path)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size / 4),
        child: Image.asset(path, width: size, height: size, fit: BoxFit.contain),
      );
    }
    final bg = bankColor(logoKey);
    final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black87;
    final text = bankInitials(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size / 4)),
      child: Text(text,
          maxLines: 1,
          style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: size * (text.length > 3 ? 0.27 : 0.36))),
    );
  }
}

/// Avatar de una cuenta de efectivo.
class CashAvatar extends StatelessWidget {
  const CashAvatar({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(size / 4)),
      child: Icon(Icons.payments_outlined, color: scheme.onSecondaryContainer, size: size * 0.55),
    );
  }
}
