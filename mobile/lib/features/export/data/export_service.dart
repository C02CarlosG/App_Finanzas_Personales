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

/// Lee los datos locales, genera el archivo en el dispositivo (sin red) y lo entrega.
class ExportService {
  ExportService({required this.repository, required this.sharer});

  final ExportRepository repository;
  final FileSharer sharer;

  Future<ExportData> prepare(ExportRequest request, {required String userName, required String userEmail, required DateTime now}) =>
      repository.load(request, userName: userName, userEmail: userEmail, now: now);

  /// Genera el archivo del [format] pedido (el PDF es asíncrono) y devuelve su nombre y contenido.
  Future<ExportFile> generate(ExportData data, ExportFormat format) async => ExportFile(
        name: '${data.baseFileName}.${format.extension}',
        mimeType: format.mimeType,
        bytes: switch (format) {
          ExportFormat.excel => buildXlsx(data),
          ExportFormat.pdf => await buildPdf(data),
        },
      );

  Future<ExportFile> exportAndShare(ExportData data, ExportFormat format) async {
    final file = await generate(data, format);
    await sharer.share(file);
    return file;
  }
}
