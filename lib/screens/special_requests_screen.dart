import 'package:flutter/material.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';

/// Admin: the quick special requests the cashier can tick ("No onion",
/// "Extra cheese" ...). Add, rename, give an extra charge, switch off, delete.
class SpecialRequestsScreen extends StatelessWidget {
  const SpecialRequestsScreen({super.key});

  Future<void> _edit(BuildContext context, [Map<String, dynamic>? existing]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _EditDialog(existing: existing),
    );
    if (result == null) return;
    final fields = {
      'name': result['name'],
      'price_delta': result['price_delta'],
      'stock_item_id': result['stock_item_id'],
      'stock_qty': result['stock_qty'],
    };
    if (existing == null) {
      await LocalStore.insert('modifiers', {'id': LocalStore.newId(), ...fields, 'active': true});
    } else {
      await LocalStore.patch('modifiers', existing['id'], fields);
    }
    SyncService.instance.syncNow();
  }

  Future<void> _toggle(Map<String, dynamic> m, bool v) async {
    await LocalStore.patch('modifiers', m['id'], {'active': v});
    SyncService.instance.syncNow();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this special request?'),
        content: Text('"${m['name']}" will be removed from the order screen. '
            'Orders already taken keep their notes. You can switch it off instead.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await LocalStore.delete('modifiers', m['id'] as String);
      SyncService.instance.syncNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final list = LocalStore.rows('modifiers')
          ..sort((a, b) =>
              '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Special requests',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                    onPressed: () => _edit(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add request'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                  'These appear as quick buttons when the cashier adds a special request. An extra charge is added to the item price. Link a request to a stock item so stock is right: "Extra cheese" uses cheese, "No onion" saves onion. Cashiers can still type their own note.',
                  style: TextStyle(color: Brand.muted)),
              const SizedBox(height: 16),
              Expanded(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: list.isEmpty
                      ? const Center(child: Text('No special requests yet'))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final m = list[i];
                            final active = m['active'] != false;
                            final extra = n(m['price_delta']);
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('${m['name']}',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 16,
                                                color: active ? Brand.navy : Brand.muted)),
                                        Text(
                                            [
                                              extra > 0 ? 'Extra charge ${money(extra)}' : 'No extra charge',
                                              if (m['stock_item_id'] != null)
                                                '${n(m['stock_qty']) >= 0 ? 'uses' : 'saves'} ${n(m['stock_qty']).abs()} '
                                                    '${LocalStore.row('stock_items', m['stock_item_id'])?['unit'] ?? ''} '
                                                    '${LocalStore.row('stock_items', m['stock_item_id'])?['name'] ?? ''}',
                                            ].join(' · '),
                                            style: const TextStyle(
                                                color: Brand.muted, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Edit',
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _edit(context, m),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(context, m),
                                  ),
                                  Tooltip(
                                    message: active ? 'Switch off' : 'Switch on',
                                    child: Switch(
                                        value: active, onChanged: (v) => _toggle(m, v)),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _extra;
  late final TextEditingController _qty;
  String? _stockId;
  bool _saves = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: '${widget.existing?['name'] ?? ''}');
    final d = n(widget.existing?['price_delta']);
    _extra = TextEditingController(text: d > 0 ? d.toStringAsFixed(2) : '');
    _stockId = widget.existing?['stock_item_id'] as String?;
    final q = n(widget.existing?['stock_qty']);
    _saves = q < 0;
    _qty = TextEditingController(text: q == 0 ? '' : '${q.abs()}');
  }

  @override
  void dispose() {
    _name.dispose();
    _extra.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    final clash = LocalStore.rows('modifiers').any((m) =>
        '${m['name']}'.toLowerCase() == name.toLowerCase() &&
        m['id'] != widget.existing?['id']);
    if (clash) {
      setState(() => _error = 'There is already a special request with that name.');
      return;
    }
    final extra = double.tryParse(_extra.text.trim().replaceAll(',', '.')) ?? 0;
    if (extra < 0) {
      setState(() => _error = 'The extra charge cannot be negative.');
      return;
    }
    final qty = double.tryParse(_qty.text.trim().replaceAll(',', '.')) ?? 0;
    if (_stockId != null && qty <= 0) {
      setState(() => _error = 'Enter how much of the stock item one request uses or saves.');
      return;
    }
    Navigator.pop(context, {
      'name': name,
      'price_delta': round2(extra),
      'stock_item_id': _stockId,
      'stock_qty': _stockId == null ? 0 : (_saves ? -qty : qty),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add special request' : 'Edit special request'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Name', helperText: 'For example: No onion'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _extra,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Extra charge (optional)',
                  prefixText: 'R ',
                  helperText: 'Leave empty for no charge'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              initialValue: _stockId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Affects stock (optional)'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Does not change stock')),
                for (final si in (LocalStore.rows('stock_items').where((x) => x['active'] != false).toList()
                  ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'))))
                  DropdownMenuItem<String?>(value: si['id'] as String, child: Text('${si['name']} (${si['unit']})')),
              ],
              onChanged: (v) => setState(() => _stockId = v),
            ),
            if (_stockId != null) ...[
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Uses more')),
                  ButtonSegment(value: true, label: Text('Uses less')),
                ],
                selected: {_saves},
                onSelectionChanged: (v) => setState(() => _saves = v.first),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Quantity per item',
                    suffixText: '${LocalStore.row('stock_items', _stockId)?['unit'] ?? ''}',
                    helperText: _saves ? 'For example "No onion" saves 0.02 kg onion' : 'For example "Extra cheese" uses 1 slice'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Brand.red)),
            ],
          ],
        )),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
