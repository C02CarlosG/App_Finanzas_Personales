import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Un archivo ya generado, listo para entregar al usuario.
class ExportFile {
  const ExportFile({required this.name, required this.mimeType, required this.bytes});

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

/// Entrega el archivo al usuario (hoja para compartir del sistema). Se sustituye en las pruebas.
abstract class FileSharer {
  /// `false` si el usuario cerró la hoja sin elegir destino; `true` en cualquier otro caso (incluido cuando la
  /// plataforma no informa qué pasó).
  Future<bool> share(ExportFile file);
}

/// Abre la hoja para compartir del sistema (correo, WhatsApp, Drive, «guardar en archivos»…). El archivo viaja
/// en memoria; en web cae a una descarga.
class SharePlusFileSharer implements FileSharer {
  const SharePlusFileSharer();

  @override
  Future<bool> share(ExportFile file) async {
    final result = await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(file.bytes, mimeType: file.mimeType, name: file.name)],
      fileNameOverrides: [file.name],
      subject: file.name,
      title: 'Compartir reporte',
    ));
    return result.status != ShareResultStatus.dismissed;
  }
}
