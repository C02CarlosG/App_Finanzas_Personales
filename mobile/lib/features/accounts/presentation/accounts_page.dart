import 'package:flutter/material.dart';

import '../../../core/ui/feature_placeholder.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) => const FeaturePlaceholder(
        title: 'Bancos',
        icon: Icons.account_balance,
        description: 'Tus cuentas bancarias y efectivo, con su saldo actual.',
        plannedIn: 'Paso 4',
        items: [
          'Selector visual de bancos con logo',
          'Saldo inicial y tipo de cuenta (débito o crédito)',
          'Efectivo en mano',
        ],
      );
}
