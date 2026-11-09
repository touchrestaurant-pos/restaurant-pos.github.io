import 'package:flutter/material.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../receipt/receipt_service.dart';
import '../theme.dart';

/// Recent orders: find one, open its receipt, print, download, email or refund.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  String _search = '';
  String _filter = 'all'; // all, unpaid, paid, cancelled

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final all = LocalStore.rows('orders').toList()
          ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
        final shown = all.where((o) {
          if (_search.isNotEmpty && !'${o['order_ref']}'.toLowerCase().contains(_search.toLowerCase())) {
            return false;
          }
          switch (_filter) {
            case 'unpaid':
              return o['paid'] != true && o['status'] != 'void';
            case 'paid':
              return o['paid'] == true && o['status'] != 'void';
            case 'cancelled':
              return o['status'] == 'void';
            default:
              return true;
          }
        }).toList();

        Widget chip(String k, String label) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(label: Text(label), selected: _filter == k, onSelected: (_) => setState(() => _filter = k)));

        return ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Orders',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
          const SizedBox(height: 4),
          const Text('The last 2 days of orders. Tap an order to see its receipt.',
              style: TextStyle(color: Brand.muted)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 220,
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(hintText: 'Order number', prefixIcon: Icon(Icons.search), isDense: true),
              ),
            ),
            chip('all', 'All · ${all.length}'),
            chip('paid', 'Paid'),
            chip('unpaid', 'Unpaid'),
            chip('cancelled', 'Cancelled'),
          ]),
          const SizedBox(height: 12),
          Card(
            child: shown.isEmpty
                ? const Padding(padding: EdgeInsets.all(24), child: Text('No orders found.'))
                : Column(children: [
                    for (final o in shown)
                      ListTile(
                        onTap: () => showReceiptDialog(context, o['id'] as String),
                        leading: const Icon(Icons.receipt_long, color: Brand.navy),
                        title: Text(
                            '#${o['order_ref']} · ${money(n(o['total']))}'
                            '${o['invoice_no'] != null ? ' · INV-${'${o['invoice_no']}'.padLeft(6, '0')}' : ''}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(_subtitle(o)),
                        trailing: _badge(o),
                      ),
                  ]),
          ),
        ]);
      },
    );
  }

  String _subtitle(Map<String, dynamic> o) {
    final t = parseTime(o['created_at']);
    final when = t == null
        ? ''
        : '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    const types = {'eat_in': 'Eat in', 'take_away': 'Take away', 'delivery': 'Delivery'};
    final items = OrderRepo.liveItemsFor(o['id'] as String).map((e) => '${e['qty']}x ${e['name']}').join(', ');
    return '$when · ${types[o['order_type']] ?? ''}${o['table_no'] != null ? ' ${o['table_no']}' : ''}\n$items';
  }

  Widget _badge(Map<String, dynamic> o) {
    String text;
    Color bg;
    if (o['status'] == 'void') {
      text = 'Cancelled';
      bg = const Color(0xFFF8D7DB);
    } else if (o['paid'] != true) {
      text = OrderRepo.paidAmount(o['id'] as String) > 0 ? 'Part paid' : 'Unpaid';
      bg = const Color(0xFFFFF1CC);
    } else {
      text = 'Paid';
      bg = const Color(0xFFDDF3E6);
    }
    return Chip(label: Text(text), backgroundColor: bg);
  }
}
