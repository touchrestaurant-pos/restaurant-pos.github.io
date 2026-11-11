import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../receipt/receipt_service.dart';
import '../theme.dart';
import '../widgets/payment_dialog.dart';

bool get _isManager => const ['admin', 'supervisor'].contains(AuthService.instance.role);

/// Cashiers may give up to this much discount; supervisors and admins any amount.
const _cashierMaxDiscountPct = 10.0;

/// Take an order: pick items, add special requests, discount, pay now (or split
/// the bill), or send it and pay later. Also tables and open orders.
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
  final _custName = TextEditingController();
  final _custPhone = TextEditingController();
  final _custAddress = TextEditingController();
  String _view = 'menu'; // menu, tables
  double _discount = 0;
  String _discountReason = '';

  /// When set, the cart adds items to this unpaid order instead of a new one.
  String? _editingOrderId;

  double get _itemsTotal => round2(_cart.fold<double>(0, (s, l) => s + l.total));
  Totals get _totals => Totals(_itemsTotal, _discount, vatRate(),
      standardTotal: _cart.where((l) => l.vatType == 'standard').fold<double>(0, (s, l) => s + l.total));
  int get _count => _cart.fold<int>(0, (s, l) => s + l.qty);
  Map<String, dynamic>? get _editingOrder =>
      _editingOrderId == null ? null : LocalStore.row('orders', _editingOrderId);

  @override
  void dispose() {
    _table.dispose();
    _custName.dispose();
    _custPhone.dispose();
    _custAddress.dispose();
    super.dispose();
  }

  Future<void> _add(Map<String, dynamic> p, int left) async {
    if (left <= 0) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${p['name']} shows as out of stock'),
          content: const Text(
              'The stock count says there is not enough to make this. If you can still make it, sell it anyway and ask the stock person to do a stock count.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Don\'t sell')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sell anyway')),
          ],
        ),
      );
      if (go != true) return;
    }
    setState(() {
      final i = _cart.indexWhere((l) => l.productId == p['id'] && l.notes.isEmpty && l.modifierIds.isEmpty);
      if (i >= 0) {
        _cart[i].qty++;
      } else {
        _cart.add(CartLine(
            productId: p['id'] as String,
            name: p['name'] as String,
            price: n(p['price']).toDouble(),
            vatType: '${p['vat_type'] ?? 'standard'}'));
      }
    });
  }

  void _clear() => setState(() {
        _cart.clear();
        _table.clear();
        _custName.clear();
        _custPhone.clear();
        _custAddress.clear();
        _discount = 0;
        _discountReason = '';
        _editingOrderId = null;
      });

  Future<void> _editNotes(CartLine line, VoidCallback refresh) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NotesDialog(
          initial: line.notes,
          pickedIds: line.modifierIds,
          item: line.name,
          categoryId: LocalStore.row('products', line.productId)?['category_id'] as String?),
    );
    if (result != null) {
      line.notes = result['notes'] as String;
      line.extra = (result['extra'] as num).toDouble();
      line.modifierIds = (result['modifier_ids'] as List).cast<String>();
      refresh();
    }
  }

  Future<void> _editDiscount(VoidCallback refresh) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _DiscountDialog(itemsTotal: _itemsTotal, current: _discount, reason: _discountReason),
    );
    if (res != null) {
      _discount = (res['amount'] as num).toDouble();
      _discountReason = res['reason'] as String;
      refresh();
    }
  }

  void _toast(String msg, {String? orderId}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 8),
        action: orderId == null
            ? null
            : SnackBarAction(label: 'Receipt', onPressed: () => showReceiptDialog(context, orderId)),
      ));
  }

  Future<void> _submit({required bool payNow}) async {
    if (_cart.isEmpty) return;
    if (_type == 'delivery' && (_custAddress.text.trim().isEmpty || _custPhone.text.trim().isEmpty)) {
      _toast('A delivery needs the customer\'s phone number and address.');
      return;
    }
    final t = _totals;
    var payments = <Map<String, dynamic>>[];
    if (payNow && t.total > 0) {
      final taken = await collectPayments(context, t.total);
      if (taken == null) return;
      payments = taken;
    }
    final lines = List<CartLine>.from(_cart);
    final id = await OrderRepo.create(
      lines: lines,
      type: _type,
      table: _type == 'eat_in' ? _table.text : null,
      customerName: _custName.text,
      customerPhone: _type == 'eat_in' ? null : _custPhone.text,
      deliveryAddress: _type == 'delivery' ? _custAddress.text : null,
      discount: _discount,
      discountReason: _discountReason,
      payments: payments,
    );
    SyncService.instance.syncNow();
    if (!mounted) return;
    _clear();
    final o = LocalStore.row('orders', id);
    final change = payments.fold<double>(0, (s, p) => s + n(p['change_given']).toDouble());
    final balance = OrderRepo.balance(id);
    final msg = StringBuffer('Order #${o?['order_ref']} sent to the kitchen');
    if (payments.isEmpty) {
      msg.write(' · not paid yet');
    } else if (balance > 0.005) {
      msg.write(' · ${money(balance)} still to pay');
    }
    if (change > 0) msg.write(' · change ${money(change)}');
    _toast(msg.toString(), orderId: id);
    if (balance <= 0.005 && payments.isNotEmpty) await maybeAutoPrint(id);
    maybePrintKitchenTicket(id);
  }

  Future<void> _submitAdded() async {
    final id = _editingOrderId;
    if (id == null || _cart.isEmpty) return;
    final ref = _editingOrder?['order_ref'];
    final before = OrderRepo.itemsFor(id).map((i) => i['id']).toSet();
    await OrderRepo.addItems(id, List<CartLine>.from(_cart));
    maybePrintKitchenTicket(id, onlyItemIds: OrderRepo.itemsFor(id).map((i) => i['id']).where((x) => !before.contains(x)).toSet());
    SyncService.instance.syncNow();
    if (!mounted) return;
    _clear();
    _toast('Items added to order #$ref and sent to the kitchen', orderId: id);
  }

  void _startAdding(String orderId) {
    final o = LocalStore.row('orders', orderId);
    setState(() {
      _cart.clear();
      _discount = 0;
      _discountReason = '';
      _editingOrderId = orderId;
      _view = 'menu';
      if (o != null) {
        _type = '${o['order_type']}';
        _table.text = '${o['table_no'] ?? ''}';
      }
    });
  }

  Future<void> _showOpenOrders({String? table}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _OpenOrdersDialog(table: table, onAddItems: _startAdding),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showCancel() async {
    await showDialog<void>(context: context, builder: (_) => const _CancelDialog());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final left = _view == 'tables' ? _tables() : _products();
          if (wide) {
            return Row(
              children: [
                Expanded(child: Column(children: [_viewSwitch(), Expanded(child: left)])),
                SizedBox(
                  width: 390,
                  child: Material(color: Colors.white, child: _cartPanel(() => setState(() {}))),
                ),
              ],
            );
          }
          return Column(
            children: [
              _viewSwitch(),
              Expanded(child: left),
              Material(
                color: Colors.white,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton(
                      onPressed: _cart.isEmpty && _editingOrderId == null ? null : _openCartSheet,
                      child: Text(_cart.isEmpty
                          ? (_editingOrderId != null ? 'Adding to an order · no items yet' : 'No items yet')
                          : 'View order · $_count items · ${money(_totals.total)}'),
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

  Widget _viewSwitch() {
    final tables = n(companyRow()?['table_count'] ?? 12).toInt();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(value: 'menu', icon: Icon(Icons.restaurant_menu, size: 18), label: Text('Menu')),
            if (tables > 0)
              const ButtonSegment(value: 'tables', icon: Icon(Icons.table_restaurant, size: 18), label: Text('Tables')),
          ],
          selected: {tables > 0 ? _view : 'menu'},
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
        const Spacer(),
        TextButton.icon(
            onPressed: () => _showOpenOrders(),
            icon: const Icon(Icons.receipt_long, size: 18),
            label: Text('Open orders · ${_openOrders().length}')),
      ]),
    );
  }

  static List<Map<String, dynamic>> _openOrders() => LocalStore.rows('orders')
      .where((o) => o['paid'] != true && o['status'] != 'void')
      .toList()
    ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));

  Widget _tables() {
    final count = n(companyRow()?['table_count'] ?? 12).toInt();
    final open = _openOrders().where((o) => o['order_type'] == 'eat_in' && o['table_no'] != null).toList();
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 170, mainAxisExtent: 110, crossAxisSpacing: 12, mainAxisSpacing: 12),
      itemCount: count,
      itemBuilder: (context, i) {
        final t = '${i + 1}';
        final orders = open.where((o) => '${o['table_no']}'.trim() == t).toList();
        final busy = orders.isNotEmpty;
        final due = orders.fold<double>(0, (s, o) => s + OrderRepo.balance(o['id'] as String));
        final since = orders
            .map((o) => parseTime(o['created_at']))
            .whereType<DateTime>()
            .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
        return Material(
          color: busy ? const Color(0xFFFFF4D6) : Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: busy ? Brand.gold : Brand.border, width: busy ? 2 : 1)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              if (busy) {
                _showOpenOrders(table: t);
              } else {
                setState(() {
                  _editingOrderId = null;
                  _type = 'eat_in';
                  _table.text = t;
                  _view = 'menu';
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Table $t', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Brand.navy)),
                const Spacer(),
                if (busy) ...[
                  Text(money(due), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                  Text(
                      '${orders.length} order${orders.length == 1 ? '' : 's'}'
                      '${since == null ? '' : ' · ${DateTime.now().difference(since).inMinutes} min'}',
                      style: const TextStyle(color: Brand.muted, fontSize: 12)),
                ] else
                  const Text('Free', style: TextStyle(color: Brand.green, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        );
      },
    );
  }

  void _openCartSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.88,
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
                child: ChoiceChip(label: const Text('All'), selected: _catId == null, onSelected: (_) => setState(() => _catId = null)),
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
                      maxCrossAxisExtent: 230, mainAxisExtent: 116, crossAxisSpacing: 12, mainAxisSpacing: 12),
                  itemCount: products.length,
                  itemBuilder: (context, i) {
                    final p = products[i];
                    final inCart = _cart.where((l) => l.productId == p['id']).fold<int>(0, (s, l) => s + l.qty);
                    final left = (canMake[p['id']] ?? 9999) - inCart;
                    return _ProductTile(
                      name: p['name'] as String,
                      description: (p['description'] ?? '') as String,
                      price: n(p['price']),
                      left: left,
                      inCart: inCart,
                      onTap: () => _add(p, left),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _cartPanel(VoidCallback refresh, {VoidCallback? onDone}) {
    final editing = _editingOrder;
    final t = _totals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (editing != null)
          Container(
            color: const Color(0xFFFFF4D6),
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(children: [
              Expanded(
                child: Text(
                    'Adding items to order #${editing['order_ref']}'
                    '${editing['table_no'] != null ? ' · Table ${editing['table_no']}' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              TextButton(
                  onPressed: () {
                    _clear();
                    refresh();
                  },
                  child: const Text('Stop')),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(editing != null ? 'Items to add' : 'Current order',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                  TextButton(onPressed: _showCancel, child: const Text('Cancel an order')),
                ],
              ),
              if (editing == null) ...[
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
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Table number', isDense: true),
                  ),
                ],
                if (_type != 'eat_in') ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _custName,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(labelText: 'Customer name', isDense: true))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: _custPhone,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Phone', isDense: true))),
                  ]),
                ],
                if (_type == 'delivery') ...[
                  const SizedBox(height: 8),
                  TextField(
                      controller: _custAddress,
                      decoration: const InputDecoration(labelText: 'Delivery address', isDense: true)),
                ],
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _cart.isEmpty
              ? const Center(child: Text('Tap items to add them', style: TextStyle(color: Brand.muted)))
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
                                  if (_discount > _itemsTotal) _discount = _itemsTotal;
                                  refresh();
                                },
                              ),
                              SizedBox(
                                width: 30,
                                child: Text('${l.qty}',
                                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
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
                              Expanded(child: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                              Text(money(l.total), style: const TextStyle(fontWeight: FontWeight.w800)),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 110, top: 4),
                            child: InkWell(
                              onTap: () => _editNotes(l, refresh),
                              child: l.notes.isEmpty
                                  ? const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 6),
                                      child: Text('+ Add special request',
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Brand.red)),
                                    )
                                  : Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                          color: const Color(0xFFFBE3A6), borderRadius: BorderRadius.circular(6)),
                                      child: Text(l.notes.toUpperCase(),
                                          style: const TextStyle(
                                              fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF4A2F00))),
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
                if (editing == null) ...[
                  Row(children: [
                    const Expanded(child: Text('Items')),
                    Text(money(_itemsTotal)),
                  ]),
                  Row(children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                          onPressed: _cart.isEmpty ? null : () => _editDiscount(refresh),
                          icon: const Icon(Icons.local_offer_outlined, size: 16),
                          label: Text(_discount > 0 ? 'Discount: $_discountReason' : 'Add discount',
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                    if (_discount > 0) Text('-${money(_discount)}', style: const TextStyle(color: Brand.red)),
                  ]),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(editing != null ? 'Added (incl. VAT)' : 'Total (incl. VAT)',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(money(editing != null ? _itemsTotal : t.total),
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                if (editing != null)
                  FilledButton(
                    onPressed: _cart.isEmpty
                        ? null
                        : () async {
                            await _submitAdded();
                            onDone?.call();
                          },
                    child: Text('Add to order #${editing['order_ref']}'),
                  )
                else ...[
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
                          onPressed: _cart.isNotEmpty
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
                    onPressed: _cart.isNotEmpty
                        ? () async {
                            await _submit(payNow: true);
                            onDone?.call();
                          }
                        : null,
                    child: Text('Pay ${money(t.total)}'),
                  ),
                ],
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
      color: out ? const Color(0xFFDDE2EE) : (selected ? const Color(0xFFEAEFFA) : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? Brand.navy : Brand.border, width: selected ? 2 : 1),
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
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: out ? Brand.muted : Brand.navy)),
                  ),
                  if (selected)
                    Container(
                      constraints: const BoxConstraints(minWidth: 24),
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Brand.navy, borderRadius: BorderRadius.circular(12)),
                      child: Text('$inCart',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                ],
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(money(price),
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: out ? Brand.muted : Brand.navy)),
                  if (out)
                    const _Badge('Out of stock', Brand.muted, Colors.white)
                  else if (low)
                    _Badge('Low · $left left', const Color(0xFFFBE3A6), const Color(0xFF7A4B00))
                  else if (left < 9000)
                    Text('$left left',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Brand.green)),
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
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: foreground)),
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

/// Discount on the whole order, as a percentage or a Rand amount, with a reason.
class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.itemsTotal, required this.current, required this.reason});
  final double itemsTotal;
  final double current;
  final String reason;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  String _mode = 'pct';
  late final TextEditingController _value;
  late final TextEditingController _reason;

  @override
  void initState() {
    super.initState();
    _mode = widget.current > 0 ? 'amount' : 'pct';
    _value = TextEditingController(text: widget.current > 0 ? widget.current.toStringAsFixed(2) : '');
    _reason = TextEditingController(text: widget.reason);
  }

  double get _amount {
    final v = double.tryParse(_value.text.replaceAll(',', '.')) ?? 0;
    final a = _mode == 'pct' ? widget.itemsTotal * v / 100 : v;
    return round2(a.clamp(0, widget.itemsTotal).toDouble());
  }

  double get _pct => widget.itemsTotal <= 0 ? 0 : _amount / widget.itemsTotal * 100;

  @override
  Widget build(BuildContext context) {
    final overLimit = !_isManager && _pct > _cashierMaxDiscountPct + 0.001;
    final valid = _amount > 0 && _reason.text.trim().isNotEmpty && !overLimit;
    return AlertDialog(
      title: const Text('Discount'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'pct', label: Text('Percentage')),
              ButtonSegment(value: 'amount', label: Text('Rand amount')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() {
              _mode = s.first;
              _value.clear();
            }),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            if (_mode == 'pct')
              for (final p in [5, 10, 15, 20, 50, 100])
                ActionChip(label: Text('$p%'), onPressed: () => setState(() => _value.text = '$p')),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _value,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: _mode == 'pct' ? 'Discount %' : 'Discount amount',
                prefixText: _mode == 'pct' ? null : 'R ',
                suffixText: _mode == 'pct' ? '%' : null),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in ['Staff meal', 'Loyal customer', 'Complaint', 'Manager special'])
              ActionChip(label: Text(r), onPressed: () => setState(() => _reason.text = r)),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _reason,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Reason (required, shows in reports)'),
          ),
          const SizedBox(height: 10),
          Text('Discount ${money(_amount)} (${_pct.toStringAsFixed(1)}%) · new total ${money(widget.itemsTotal - _amount)}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if (overLimit)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Cashiers can give up to 10%. Ask a supervisor for more.',
                  style: TextStyle(color: Brand.red)),
            ),
        ]),
      ),
      actions: [
        if (widget.current > 0)
          TextButton(
              onPressed: () => Navigator.pop(context, {'amount': 0, 'reason': ''}),
              child: const Text('Remove discount')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, {'amount': _amount, 'reason': _reason.text.trim()}) : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _NotesDialog extends StatefulWidget {
  const _NotesDialog({required this.initial, required this.pickedIds, required this.item, this.categoryId});
  final String? categoryId;
  final String initial;
  final List<String> pickedIds;
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
    final mods = Catalog.modifiers();
    final names = mods.map((m) => m['name'] as String).toSet();
    final parts = widget.initial.split(' · ').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    _picked = {...widget.pickedIds};
    if (_picked.isEmpty) {
      for (final m in mods) {
        if (parts.contains(m['name'])) _picked.add(m['id'] as String);
      }
    }
    _extra = TextEditingController(text: parts.where((p) => !names.contains(p)).join(' · '));
  }

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Requests limited to certain categories only show for items in them.
    final mods = Catalog.modifiers().where((m) {
      final cats = (m['category_ids'] as List?) ?? const [];
      return cats.isEmpty || cats.contains(widget.categoryId) || _picked.contains(m['id']);
    }).toList();
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
                      selected: _picked.contains(m['id']),
                      onSelected: (v) => setState(() {
                        v ? _picked.add(m['id'] as String) : _picked.remove(m['id']);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _extra,
                decoration: const InputDecoration(labelText: 'Other request (for the kitchen)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final chosen = Catalog.modifiers().where((m) => _picked.contains(m['id'])).toList();
            final parts = [
              ...chosen.map((m) => m['name'] as String),
              if (_extra.text.trim().isNotEmpty) _extra.text.trim(),
            ];
            final extra = chosen.fold<double>(0, (s, m) => s + n(m['price_delta']).toDouble());
            Navigator.pop(context, {
              'notes': parts.join(' · '),
              'extra': round2(extra),
              'modifier_ids': chosen.map((m) => m['id'] as String).toList(),
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Orders that still have to be paid: pay (or split), add items, remove items,
/// receipt, and for supervisors void.
class _OpenOrdersDialog extends StatefulWidget {
  const _OpenOrdersDialog({this.table, required this.onAddItems});
  final String? table;
  final void Function(String orderId) onAddItems;

  @override
  State<_OpenOrdersDialog> createState() => _OpenOrdersDialogState();
}

class _OpenOrdersDialogState extends State<_OpenOrdersDialog> {
  Future<void> _pay(Map<String, dynamic> o) async {
    final id = o['id'] as String;
    var balance = OrderRepo.balance(id);
    while (balance > 0.005) {
      final got = await showPaymentDialog(context, balance, alreadyPaid: OrderRepo.paidAmount(id));
      if (got == null) break;
      for (final p in got) {
        await OrderRepo.pay(id, p);
      }
      balance = OrderRepo.balance(id);
    }
    SyncService.instance.syncNow();
    if (!mounted) return;
    setState(() {});
    if (OrderRepo.balance(id) <= 0.005) {
      maybeAutoPrint(id);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Order #${o['order_ref']} paid.'),
        action: SnackBarAction(label: 'Receipt', onPressed: () => showReceiptDialog(context, id)),
      ));
    }
  }

  /// Move an order to another table. Moving two orders to the same table joins their bills on the Tables view.
  Future<void> _moveTable(Map<String, dynamic> o) async {
    final c = TextEditingController(text: '${o['table_no'] ?? ''}');
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move order #${o['order_ref']}'),
        content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'New table number')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Move')),
        ],
      ),
    );
    if (t == null || t.isEmpty) return;
    await LocalStore.patch('orders', o['id'], {'table_no': t});
    SyncService.instance.syncNow();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _items(Map<String, dynamic> o) async {
    await showDialog<void>(context: context, builder: (_) => _OrderItemsDialog(orderId: o['id'] as String));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final open = LocalStore.rows('orders')
        .where((o) =>
            o['paid'] != true &&
            o['status'] != 'void' &&
            (widget.table == null || '${o['table_no'] ?? ''}'.trim() == widget.table))
        .toList()
      ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));

    return AlertDialog(
      title: Text(widget.table == null ? 'Open orders (not paid yet)' : 'Table ${widget.table}'),
      content: SizedBox(
        width: 560,
        child: open.isEmpty
            ? const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('Nothing waiting to be paid.'))
            : ListView.separated(
                shrinkWrap: true,
                itemCount: open.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final o = open[i];
                  final id = o['id'] as String;
                  final items = OrderRepo.liveItemsFor(id);
                  final summary = items.map((e) => '${e['qty']}× ${e['name']}').join(', ');
                  final paid = OrderRepo.paidAmount(id);
                  final balance = OrderRepo.balance(id);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                          '#${o['order_ref']} · ${money(n(o['total']))}'
                          '${o['table_no'] != null ? ' · Table ${o['table_no']}' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (paid > 0)
                        Text('Paid ${money(paid)} · still owed ${money(balance)}',
                            style: const TextStyle(color: Brand.amber, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                          onPressed: () => _pay(o),
                          child: Text('Pay ${money(balance)}'),
                        ),
                        OutlinedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            widget.onAddItems(id);
                          },
                          child: const Text('Add items'),
                        ),
                        OutlinedButton(onPressed: () => _items(o), child: const Text('Remove items')),
                        if (o['order_type'] == 'eat_in')
                          OutlinedButton(onPressed: () => _moveTable(o), child: const Text('Move table')),
                        TextButton(onPressed: () => showReceiptDialog(context, id), child: const Text('Bill')),
                        if (_isManager && paid <= 0)
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: Brand.red),
                            onPressed: () async {
                              await OrderRepo.setStatus(id, 'void', voidReason: 'Voided by ${AuthService.instance.fullName}');
                              SyncService.instance.syncNow();
                              setState(() {});
                            },
                            child: const Text('Void'),
                          ),
                      ]),
                    ]),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

/// Take items off an unpaid order. Items the kitchen has finished need a supervisor.
class _OrderItemsDialog extends StatefulWidget {
  const _OrderItemsDialog({required this.orderId});
  final String orderId;

  @override
  State<_OrderItemsDialog> createState() => _OrderItemsDialogState();
}

class _OrderItemsDialogState extends State<_OrderItemsDialog> {
  @override
  Widget build(BuildContext context) {
    final items = OrderRepo.liveItemsFor(widget.orderId);
    final paid = OrderRepo.paidAmount(widget.orderId);
    return AlertDialog(
      title: const Text('Remove items'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (paid > 0)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Part of this order is already paid. Remove items only if the total stays above what was paid.',
                  style: TextStyle(color: Brand.muted)),
            ),
          for (final it in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${it['qty']}× ${it['name']}'),
              subtitle: Text([
                money(n(it['qty']) * n(it['unit_price'])),
                if (it['done'] == true) 'made by the kitchen',
              ].join(' · ')),
              trailing: TextButton(
                style: TextButton.styleFrom(foregroundColor: Brand.red),
                onPressed: (it['done'] == true && !_isManager)
                    ? null
                    : () async {
                        final o = LocalStore.row('orders', widget.orderId);
                        final newTotal = n(o?['total']) - n(it['qty']) * n(it['unit_price']);
                        if (newTotal + 0.005 < paid) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('The total would drop below what was already paid. Refund instead.')));
                          return;
                        }
                        await OrderRepo.removeItem(it['id'] as String);
                        SyncService.instance.syncNow();
                        setState(() {});
                      },
                child: Text(it['done'] == true && !_isManager ? 'Ask supervisor' : 'Remove'),
              ),
            ),
          if (items.isEmpty) const Text('No items left on this order.'),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}

/// Cancel an order that is still in the kitchen queue. The kitchen is alerted
/// with the reason. A paid order can only be cancelled by a supervisor or admin,
/// online, and its money is refunded in the same step.
class _CancelDialog extends StatefulWidget {
  const _CancelDialog();

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  bool _busy = false;

  Future<String?> _askReason(String ref, {required bool paid}) {
    final c = TextEditingController();
    const quick = ['Customer changed their mind', 'Wrong order captured', 'Waited too long', 'Customer left'];
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
                if (paid)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('This order was paid. The full amount is recorded as a refund to the customer.',
                        style: TextStyle(color: Brand.red, fontWeight: FontWeight.w700)),
                  ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final q in quick) ActionChip(label: Text(q), onPressed: () => set(() => c.text = q)),
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
              style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
              onPressed: c.text.trim().isEmpty ? null : () => Navigator.pop(ctx, c.text.trim()),
              child: Text(paid ? 'Cancel and refund' : 'Cancel order'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancel(Map<String, dynamic> o) async {
    final id = o['id'] as String;
    final paidAmount = OrderRepo.paidAmount(id);
    final hasPayment = paidAmount > 0 || o['paid'] == true;
    final reason = await _askReason('${o['order_ref']}', paid: hasPayment);
    if (reason == null || !mounted) return;
    final text = 'Cancelled by customer: $reason (by ${AuthService.instance.fullName})';
    if (!hasPayment) {
      await OrderRepo.setStatus(id, 'void', voidReason: text);
      SyncService.instance.syncNow();
      if (mounted) setState(() {});
      return;
    }
    // Paid: done on the server so the cancel and the refund happen together.
    setState(() => _busy = true);
    try {
      await SyncService.instance.syncNow(); // make sure the order and payments are on the server
      final db = Supabase.instance.client;
      final pays = OrderRepo.paymentsFor(id);
      final acctPaid = round2(pays.where((p) => p['method'] == 'account').fold<double>(0, (s, p) => s + n(p['amount']).toDouble()));
      final otherMethod = pays.where((p) => p['method'] != 'account').isNotEmpty
          ? '${pays.firstWhere((p) => p['method'] != 'account')['method']}'
          : 'cash';
      final already = await db.from('refunds').select('amount,method').eq('order_id', id);
      final refunded = already.fold<double>(0, (s, r) => s + n(r['amount']).toDouble());
      final acctBack = already.where((r) => r['method'] == 'account').fold<double>(0, (s, r) => s + n(r['amount']).toDouble());
      final toRefund = round2(paidAmount - refunded);
      final toAccount = round2((acctPaid - acctBack).clamp(0, toRefund));
      final toCustomer = round2(toRefund - toAccount);
      Future<void> refund(double amount, String method) => db.rpc('issue_refund', params: {
            'p_order_id': id,
            'p_amount': amount,
            'p_method': method,
            'p_reason': 'Order cancelled: $reason',
            'p_restock': false,
          });
      if (toAccount > 0.005) await refund(toAccount, 'account');
      if (toCustomer > 0.005) await refund(toCustomer, otherMethod);
      await db.from('orders').update({'status': 'void', 'void_reason': text}).eq('id', id);
      await SyncService.instance.syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Order #${o['order_ref']} cancelled. ${toAccount > 0.005 ? '${money(toAccount)} was credited to the customer account. ' : ''}Give the customer ${money(toCustomer > 0 ? toCustomer : 0)} back.')));
      }
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cancelling a paid order needs an internet connection.')));
      }
    }
    if (mounted) setState(() => _busy = false);
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
        width: 480,
        child: open.isEmpty
            ? const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('No open orders to cancel.'))
            : ListView.separated(
                shrinkWrap: true,
                itemCount: open.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final o = open[i];
                  final id = o['id'] as String;
                  final items = OrderRepo.liveItemsFor(id);
                  final summary = items.map((e) => '${e['qty']}× ${e['name']}').join(', ');
                  final hasPayment = o['paid'] == true || OrderRepo.paidAmount(id) > 0;
                  final allowed = !hasPayment || _isManager;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('#${o['order_ref']} · ${money(n(o['total']))}${hasPayment ? ' · PAID' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: allowed
                        ? TextButton(
                            style: TextButton.styleFrom(foregroundColor: Brand.red),
                            onPressed: _busy ? null : () => _cancel(o),
                            child: const Text('Cancel'),
                          )
                        : const Text('Paid: ask a\nsupervisor', textAlign: TextAlign.right, style: TextStyle(color: Brand.muted)),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
