import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/accounts/presentation/accounts_page.dart';
import '../../features/accounts/presentation/add_account_page.dart';
import '../../features/accounts/presentation/edit_account_page.dart';
import '../../features/auth/presentation/login_page.dart';
import '../../features/categories/presentation/categories_page.dart';
import '../../features/dashboard/presentation/dashboard_page.dart';
import '../../features/profile/presentation/profile_page.dart';
import '../../features/sync/presentation/problems_page.dart';
import '../../features/reports/presentation/reports_page.dart';
import '../../features/transactions/presentation/transaction_form_page.dart';
import '../providers.dart';
import '../ui/home_shell.dart';

abstract final class AppRoutes {
  static const loading = '/cargando';
  static const login = '/ingresar';
  static const reauth = '/reingresar';
  static const problems = '/problemas';
  static const accountNew = '/cuentas/nueva';
  static String account(String id) => '/cuentas/$id';
  static const movements = '/movimientos';
  static const transactionNewPath = '/movimientos/nuevo';
  static String transactionNew(String type) => '/movimientos/nuevo?tipo=$type';
  static String transaction(String id) => '/movimientos/$id';
  static const home = '/inicio';
  static const banks = '/bancos';
  static const categories = '/categorias';
  static const reports = '/reportes';
  static const profile = '/perfil';
}

/// Rutas con redirección según la sesión: sin sesión → login; con sesión → Inicio.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final here = state.matchedLocation;
      if (auth.isLoading) return here == AppRoutes.loading ? null : AppRoutes.loading;
      final signedIn = auth.value != null;
      if (!signedIn) return here == AppRoutes.login ? null : AppRoutes.login;
      if (here == AppRoutes.login || here == AppRoutes.loading) return AppRoutes.home;
      return null;
    },
    routes: [
      GoRoute(path: AppRoutes.loading, builder: (_, _) => const _Splash()),
      GoRoute(path: AppRoutes.login, builder: (_, _) => const LoginPage()),
      GoRoute(path: AppRoutes.reauth, builder: (_, _) => const LoginPage(reauth: true)),
      GoRoute(path: AppRoutes.problems, builder: (_, _) => const ProblemsPage()),
      // Pantallas completas (sin barra inferior) alcanzables desde cualquier pestaña.
      GoRoute(path: AppRoutes.accountNew, builder: (_, _) => const AddAccountPage()),
      // '/movimientos/nuevo' va antes que '/movimientos/:id' para que no se tome "nuevo" como un id.
      GoRoute(
        path: AppRoutes.transactionNewPath,
        builder: (_, state) =>
            TransactionFormPage(type: state.uri.queryParameters['tipo'] == 'income' ? 'income' : 'expense'),
      ),
      GoRoute(
        path: '/movimientos/:id',
        builder: (_, state) => TransactionFormPage(transactionId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/cuentas/:id',
        builder: (_, state) => EditAccountPage(accountId: state.pathParameters['id']!),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: AppRoutes.home, builder: (_, _) => const DashboardPage())]),
          StatefulShellBranch(routes: [GoRoute(path: AppRoutes.banks, builder: (_, _) => const AccountsPage())]),
          StatefulShellBranch(routes: [GoRoute(path: AppRoutes.categories, builder: (_, _) => const CategoriesPage())]),
          StatefulShellBranch(routes: [GoRoute(path: AppRoutes.reports, builder: (_, _) => const ReportsPage())]),
          StatefulShellBranch(routes: [GoRoute(path: AppRoutes.profile, builder: (_, _) => const ProfilePage())]),
        ],
      ),
    ],
  );
});

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}
