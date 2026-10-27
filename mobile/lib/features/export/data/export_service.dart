import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'export_models.dart';
import 'export_repository.dart';
import 'file_sharer.dart';
import 'pdf_builder.dart';
import 'xlsx_builder.dart';

enum ExportFormat {
  excel('Excel (.xlsx)', 'xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
  pdf('PDF', 'pdf', 'application/pdf');

  const ExportFormat(this.label, this.extension, this.mimeType);
  final String label;
  final String extension;
  final String mimeType;
}

/// Cómo se convierte [ExportData] en los bytes del archivo (se sustituye en pruebas por [buildExportBytes] directo).
typedef ExportBuilder = Future<Uint8List> Function(ExportData data, ExportFormat format);

/// Genera el archivo en el mismo hilo.
Future<Uint8List> buildExportBytes(({ExportData data, ExportFormat format}) job) async =>
    switch (job.format) {
      ExportFormat.excel => buildXlsx(job.data),
      ExportFormat.pdf => await buildPdf(job.data),
    };

/// Genera el archivo en un isolate aparte (en web, en el mismo hilo): con un año de movimientos el diseño del PDF
/// tarda segundos y no debe congelar la interfaz ni provocar un «la app no responde». `ExportData` es solo datos.
Future<Uint8List> buildInBackground(ExportData data, ExportFormat format) =>
    compute(buildExportBytes, (data: data, format: format));

/// Lee los datos locales, genera el archivo en el dispositivo (sin red) y lo entrega.
class ExportService {
  ExportService({required this.repository, required this.sharer, this.builder = buildInBackground});

  final ExportRepository repository;
  final FileSharer sharer;
  final ExportBuilder builder;

  Future<ExportData> prepare(ExportRequest request, {required String userName, required String userEmail, required DateTime now}) =>
      repository.load(request, userName: userName, userEmail: userEmail, now: now);

  /// Genera el archivo del [format] pedido y devuelve su nombre y contenido.
  Future<ExportFile> generate(ExportData data, ExportFormat format) async =>
      ExportFile(name: '${data.baseFileName}.${format.extension}', mimeType: format.mimeType, bytes: await builder(data, format));

  /// `delivered` es falso si el usuario cerró la hoja de compartir sin elegir destino.
  Future<({ExportFile file, bool delivered})> exportAndShare(ExportData data, ExportFormat format) async {
    final file = await generate(data, format);
    return (file: file, delivered: await sharer.share(file));
  }
}
