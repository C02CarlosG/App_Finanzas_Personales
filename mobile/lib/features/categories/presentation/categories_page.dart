import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/app_database.dart';
import 'category_editor.dart';

/// Categorías (spec 5.10): las de ingresos y las de gastos, editables por el usuario.
class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Builder(builder: (context) {
        final tabs = DefaultTabController.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Categorías'),
            bottom: const TabBar(tabs: [Tab(text: 'Ingresos'), Tab(text: 'Gastos')]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            heroTag: null, // varias pantallas con FAB conviven (pestañas + rutas); sin etiqueta no chocan en la transición
            key: const Key('agregar-categoria'),
            onPressed: () => showCategoryEditor(context, kind: tabs.index == 0 ? 'income' : 'expense'),
            icon: const Icon(Icons.add),
            label: const Text('Agregar'),
          ),
          body: const TabBarView(children: [_CategoryList(kind: 'income'), _CategoryList(kind: 'expense')]),
        );
      }),
    );
  }
}

class _CategoryList extends ConsumerWidget {
  const _CategoryList({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider(kind));
    return categories.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('No se pudieron cargar las categorías: $e')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(key: Key('sin-categorias'), child: Text('Aún no hay categorías. Se descargan al sincronizar.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _CategoryTile(category: list[i]),
        );
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category});

  final CategoryRow category;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('categoria-${category.id}'),
      leading: CircleAvatar(radius: 14, backgroundColor: categoryDisplayColor(category.color, category.name)),
      title: Text(category.name),
      trailing: category.isSystem ? const Chip(label: Text('Sistema'), visualDensity: VisualDensity.compact) : null,
      onTap: () => showCategoryEditor(context, kind: category.kind, category: category),
    );
  }
}
