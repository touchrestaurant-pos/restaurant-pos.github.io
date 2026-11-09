import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';
import '../widgets/payment_dialog.dart';

/// Take an order: pick items, add special requests, pay now or pay later.
class CashierScreen extends StatefulWidget {
  const CashierScreen({super.key});

  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends State<CashierScreen> {
  String? _catId;
  final List<CartLine> _cart = [];
  String _type = 'eat_in';
  final _table = TextEditingController();

  double get _total => round2(_cart.fold<double>(0, (s, l) => s + l.total));
  int get _count => _cart.fold<int>(0, (s, l) => s + l.qty);

  @override
  void dispose() {
    _table.dispose();
    super.dispose();
  }

  void _add(Map<String, dynamic> p) {
    setState(() {
      final i = _cart.indexWhere((l) => l.productId == p['id'] && l.notes.isEmpty);
      if (i >= 0) {
        _cart[i].qty++;
      } else {
        _cart.add(CartLine(
          productId: p['id'] as String,
          name: p['name'] as String,
          price: n(p['price']).toDouble(),
        ));
      }
    });
  }

  void _clear() => setState(() {
        _cart.clear();
        _table.clear();
      });

  Future<void> _editNotes(CartLine line, VoidCallback refresh) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NotesDialog(initial: line.notes, item: line.name),
    );
    if (result != null) {
      line.notes = result['notes'] as String;
      line.extra = (result['extra'] as num).toDouble();
      refresh();
    }
  }

  Future<void> _submit({required bool payNow}) async {
    if (_cart.isEmpty) return;
    Map<String, dynamic>? payment;
    if (payNow) {
      payment = await showPaymentDialog(context, _total);
      if (payment == null) return;
    }
    final lines = List<CartLine>.from(_cart);
    final ref = await OrderRepo.create(
      lines: lines,
      type: _type,
      table: _table.text,
      payment: payment,
    );
    SyncService.instance.syncNow();
    if (!mounted) return;
    _clear();
    final change = payment?['change_given'];
    final msg = StringBuffer('Order #$ref sent to the kitchen');
    if (payment == null) msg.write(' · not paid yet');
    if (change != null && n(change) > 0) msg.write(' · change ${money(n(change))}');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg.toString())));
  }

  Future<void> _showCancel() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _CancelDialog(),
    );
  }

  Future<void> _showUnpaid() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _UnpaidDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          if (wide) {
            return Row(
              children: [
                Expanded(child: _products()),
                SizedBox(
                  width: 380,
                  child: Material(
                    color: Colors.white,
                    child: _cartPanel(() => setState(() {})),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: _products()),
              Material(
                color: Colors.white,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _cart.isEmpty ? null : _openCartSheet,
                            child: Text(_cart.isEmpty
                                ? 'No items yet'
                                : 'View order · $_count items · ${money(_total)}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openCartSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.85,
          child: _cartPanel(() {
            setState(() {});
            setSheet(() {});
          }, onDone: () => Navigator.of(sheetContext).pop()),
        ),
      ),
    );
  }

  Widget _products() {
    final cats = Catalog.categories();
    final products = Catalog.products(_catId);
    final canMake = Catalog.canMakeAll();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 64,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All'),
                  selected: _catId == null,
                  onSelected: (_) => setState(() => _catId = null),
                ),
              ),
              for (final c in cats)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c['name'] as String),
                    selected: _catId == c['id'],
                    onSelected: (_) => setState(() => _catId = c['id'] as String),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: products.isEmpty
              ? const Center(child: Text('No menu items yet'))
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 230,
                    mainAxisExtent: 116,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: products.length,
                  itemBuilder: (context, i) {
                    final p = products[i];
                    final left = canMake[p['id']] ?? 9999;
                    final qtyInCart = _cart
                        .where((l) => l.productId == p['id'])
                        .fold<int>(0, (s, l) => s + l.qty);
                    return _ProductTile(
                      name: p['name'] as String,
                      description: (p['description'] ?? '') as String,
                      price: n(p['price']),
                      left: left,
                      inCart: qtyInCart,
                      onTap: left <= 0 ? null : () => _add(p),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _cartPanel(VoidCallback refresh, {VoidCallback? onDone}) {
    final canPay = _cart.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Current order',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                  TextButton(onPressed: _showUnpaid, child: const Text('Unpaid orders')),
                  TextButton(onPressed: _showCancel, child: const Text('Cancel an order')),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'eat_in', label: Text('Eat in')),
                  ButtonSegment(value: 'take_away', label: Text('Take away')),
                  ButtonSegment(value: 'delivery', label: Text('Delivery')),
                ],
                selected: {_type},
                onSelectionChanged: (s) {
                  _type = s.first;
                  refresh();
                },
              ),
              if (_type == 'eat_in') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _table,
                  decoration: const InputDecoration(
                      labelText: 'Table number', isDense: true),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _cart.isEmpty
              ? const Center(
                  child: Text('Tap items to add them',
                      style: TextStyle(color: Brand.muted)))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _cart.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final l = _cart[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _QtyButton(
                                icon: Icons.remove,
                                label: 'Decrease quantity',
                                onTap: () {
                                  l.qty--;
                                  if (l.qty <= 0) _cart.remove(l);
                                  refresh();
                                },
                              ),
                              SizedBox(
                                width: 30,
                                child: Text('${l.qty}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontWeight: FontWeight.w800)),
                              ),
                              _QtyButton(
                                icon: Icons.add,
                                label: 'Increase quantity',
                                onTap: () {
                                  l.qty++;
                                  refresh();
                                },
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(l.name,
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                              ),
                              Text(money(l.total),
                                  style: const TextStyle(fontWeight: FontWeight.w800)),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 110, top: 4),
                            child: l.notes.isEmpty
                                ? InkWell(
                                    onTap: () => _editNotes(l, refresh),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 6),
                                      child: Text('+ Add special request',
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: Brand.red)),
                                    ),
                                  )
                                : InkWell(
                                    onTap: () => _editNotes(l, refresh),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFBE3A6),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(l.notes.toUpperCase(),
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF4A2F00))),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: const BoxDecoration(
            color: Color(0xFFF3F5FA),
            border: Border(top: BorderSide(color: Brand.border)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text('Total (incl. VAT)',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    Text(money(_total),
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _cart.isEmpty
                            ? null
                            : () {
                                _clear();
                                refresh();
                              },
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        onPressed: canPay
                            ? () async {
                                await _submit(payNow: false);
                                onDone?.call();
                              }
                            : null,
                        child: const Text('Send, pay later'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: canPay
                      ? () async {
                          await _submit(payNow: true);
                          onDone?.call();
                        }
                      : null,
                  child: Text('Pay ${money(_total)}'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.name,
    required this.description,
    required this.price,
    required this.left,
    required this.inCart,
    required this.onTap,
  });
  final String name;
  final String description;
  final num price;
  final int left;
  final int inCart;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final out = left <= 0;
    final low = !out && left < 25;
    final selected = inCart > 0;
    return Material(
      color: out
          ? const Color(0xFFDDE2EE)
          : selected
              ? const Color(0xFFEAEFFA)
              : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? Brand.navy : Brand.border,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: out ? Brand.muted : Brand.navy)),
                  ),
                  if (selected)
                    Container(
                      constraints: const BoxConstraints(minWidth: 24),
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: Brand.navy, borderRadius: BorderRadius.circular(12)),
                      child: Text('$inCart',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13)),
                    ),
                ],
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(money(price),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          color: out ? Brand.muted : Brand.navy)),
                  if (out)
                    _Badge('Out of stock', Brand.muted, Colors.white)
                  else if (low)
                    _Badge('Low · $left left', const Color(0xFFFBE3A6),
                        const Color(0xFF7A4B00))
                  else if (left < 9999)
                    Text('$left left',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: Brand.green)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.background, this.foreground);
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: foreground)),
      );
}

class _QtyButton extends StatelessWidget {
  const _QtyButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          tooltip: label,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            side: const BorderSide(color: Color(0xFFC3CBDD)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          icon: Icon(icon, size: 18),
          onPressed: onTap,
        ),
      );
}

class _NotesDialog extends StatefulWidget {
  const _NotesDialog({required this.initial, required this.item});
  final String initial;
  final String item;

  @override
  State<_NotesDialog> createState() => _NotesDialogState();
}

class _NotesDialogState extends State<_NotesDialog> {
  late final Set<String> _picked;
  late final TextEditingController _extra;

  @override
  void initState() {
    super.initState();
    final names = Catalog.modifiers().map((m) => m['name'] as String).toSet();
    final parts = widget.initial
        .split(' · ')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    _picked = parts.where(names.contains).toSet();
    _extra = TextEditingController(
        text: parts.where((p) => !names.contains(p)).join(' · '));
  }

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mods = Catalog.modifiers();
    return AlertDialog(
      title: Text('Special request · ${widget.item}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in mods)
                    FilterChip(
                      label: Text(n(m['price_delta']) > 0
                          ? '${m['name']} (+${money(n(m['price_delta']))})'
                          : m['name'] as String),
                      selected: _picked.contains(m['name']),
                      onSelected: (v) => setState(() {
                        v ? _picked.add(m['name'] as String) : _picked.remove(m['name']);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _extra,
                decoration: const InputDecoration(
                    labelText: 'Other request (for the kitchen)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final parts = [..._picked, if (_extra.text.trim().isNotEmpty) _extra.text.trim()];
            final extra = Catalog.modifiers()
                .where((m) => _picked.contains(m['name']))
                .fold<double>(0, (s, m) => s + n(m['price_delta']).toDouble());
            Navigator.pop(context, {'notes': parts.join(' · '), 'extra': round2(extra)});
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Orders sent to the kitchen that still have to be paid.
class _UnpaidDialog extends StatefulWidget {
  const _UnpaidDialog();

  @override
  State<_UnpaidDialog> createState() => _UnpaidDialogState();
}

class _UnpaidDialogState extends State<_UnpaidDialog> {
  @override
  Widget build(BuildContext context) {
    final canVoid = const ['admin', 'supervisor'].contains(AuthService.instance.role);
    final unpaid = LocalStore.rows('orders')
        .where((o) => o['paid'] != true && o['status'] != 'void')
        .toList()
      ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));

    return AlertDialog(
      title: const Text('Unpaid orders'),
      content: SizedBox(
        width: 460,
        child: unpaid.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Nothing waiting to be paid.'))
            : ListView.separated(
                shrinkWrap: true,
                itemCount: unpaid.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final o = unpaid[i];
                  final items = OrderRepo.itemsFor(o['id'] as String);
                  final summary = items.map((e) => '${e['qty']}× ${e['name']}').join(', ');
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                        '#${o['order_ref']} · ${money(n(o['total']))}'
                        '${o['table_no'] != null ? ' · Table ${o['table_no']}' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (canVoid)
                          TextButton(
                            onPressed: () async {
                              await OrderRepo.setStatus(o['id'] as String, 'void',
                                  voidReason: 'Voided by ${AuthService.instance.fullName}');
                              SyncService.instance.syncNow();
                              setState(() {});
                            },
                            child: const Text('Void'),
                          ),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                          onPressed: () async {
                            final p = await showPaymentDialog(context, n(o['total']).toDouble());
                            if (p == null) return;
                            await OrderRepo.pay(o['id'] as String, p);
                            SyncService.instance.syncNow();
                            setState(() {});
                          },
                          child: const Text('Pay'),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

/// Cancel an order that is still in the kitchen queue. The kitchen is alerted
/// with the reason.
class _CancelDialog extends StatefulWidget {
  const _CancelDialog();

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  Future<String?> _askReason(String ref) {
    final c = TextEditingController();
    const quick = [
      'Customer changed their mind',
      'Wrong order captured',
      'Waited too long',
      'Customer left',
    ];
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Cancel order #$ref'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('The kitchen will see: "Cancelled by customer" with your reason.'),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final q in quick)
                    ActionChip(
                        label: Text(q),
                        onPressed: () => set(() => c.text = q)),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: c,
                  autofocus: true,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Reason (required)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              onPressed: c.text.trim().isEmpty ? null : () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Cancel order'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = LocalStore.rows('orders')
        .where((o) => const ['new', 'in_progress', 'ready'].contains(o['status']))
        .toList()
      ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
    return AlertDialog(
      title: const Text('Cancel an order'),
      content: SizedBox(
        width: 460,
        child: open.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No open orders to cancel.'))
            : ListView.separated(
                shrinkWrap: true,
                itemCount: open.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final o = open[i];
                  final items = OrderRepo.itemsFor(o['id'] as String);
                  final summary = items.map((e) => '${e['qty']}× ${e['name']}').join(', ');
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                        '#${o['order_ref']} · ${money(n(o['total']))}'
                        '${o['paid'] == true ? ' · PAID' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: TextButton(
                      style: TextButton.styleFrom(foregroundColor: Brand.red),
                      onPressed: () async {
                        final reason = await _askReason('${o['order_ref']}');
                        if (reason == null) return;
                        await OrderRepo.setStatus(o['id'] as String, 'void',
                            voidReason:
                                'Cancelled by customer: $reason (by ${AuthService.instance.fullName})');
                        SyncService.instance.syncNow();
                        if (mounted) setState(() {});
                      },
                      child: const Text('Cancel'),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
