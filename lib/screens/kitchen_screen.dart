import 'dart:async';

import 'package:flutter/material.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../platform/alerts.dart';

const _bg = Color(0xFF101E48);
const _card = Color(0xFF1E3478);
const _line = Color(0xFF34498A);
const _soft = Color(0xFFB8C3DE);
const _green = Color(0xFF1E7A4A);
const _amber = Color(0xFFF2B230);
const _red = Color(0xFFC8283A);
const _ok = Color(0xFF2FA866);

/// The kitchen queue: tap items as they are made, start an order, mark it ready.
class KitchenScreen extends StatefulWidget {
  const KitchenScreen({super.key});

  @override
  State<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends State<KitchenScreen> {
  Timer? _tick;
  String _filter = 'all'; // all, new, progress, special
  bool _alertOpen = false;
  Set<String>? _seen; // orders and added items already announced
  int _ticks = 0;
  bool get _soundOn => LocalStore.getMeta('kitchen_sound') != false;

  /// Beeps once for each new order or item added to an order.
  void _announce(List<Map<String, dynamic>> active) {
    final now = <String>{};
    for (final o in active) {
      now.add('o:${o['id']}');
      for (final i in OrderRepo.itemsFor(o['id'] as String)) {
        if (i['added_later'] == true && i['voided'] != true) now.add('i:${i['id']}');
      }
    }
    final seen = _seen;
    _seen = {...?seen, ...now};
    if (seen == null) return; // first look: nothing is "new"
    if (now.difference(seen).isNotEmpty && _soundOn) playAlert();
  }
  Future<void>? _acking;

  /// Orders cancelled in the last 12 hours that no kitchen screen has acknowledged yet.
  /// The acknowledgement is stored on the order itself, so it shows once for everyone.
  List<Map<String, dynamic>> _cancelled() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 12));
    return LocalStore.rows('orders').where((o) {
      final t = parseTime(o['voided_at']);
      return o['status'] == 'void' &&
          o['cancel_ack_at'] == null &&
          t != null &&
          t.isAfter(cutoff);
    }).toList()
      ..sort((a, b) => '${a['voided_at']}'.compareTo('${b['voided_at']}'));
  }

  Future<void> _ack(Iterable<String> ids) async {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      await LocalStore.upsert('orders', {'id': id, 'cancel_ack_at': now});
    }
    SyncService.instance.syncNow();
  }

  void _maybeAlert(List<Map<String, dynamic>> cancelled) {
    if (_alertOpen || cancelled.isEmpty) return;
    _alertOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF3A0F18),
          title: const Row(children: [
            Icon(Icons.cancel, color: Colors.white),
            SizedBox(width: 10),
            Text('ORDER CANCELLED', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final o in cancelled) ...[
                Text('#${o['order_ref']}',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                Text('${o['void_reason'] ?? 'Cancelled by customer'}',
                    style: const TextStyle(color: _soft, fontSize: 16)),
                const SizedBox(height: 12),
              ],
              const Text('Stop making these orders.',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ],
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _red, foregroundColor: Colors.white),
              onPressed: () {
                _acking = _ack(cancelled.map((o) => o['id'] as String));
                Navigator.pop(ctx);
              },
              child: const Text('OK, understood'),
            ),
          ],
        ),
      );
      // Wait until the acknowledgement is saved, so the popup cannot come back.
      try {
        await _acking;
      } catch (_) {}
      _acking = null;
      _alertOpen = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    keepScreenOn(true);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_ticks % 30 == 0) keepScreenOn(true);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    keepScreenOn(false);
    super.dispose();
  }

  Future<void> _setStatus(String id, String status) async {
    await OrderRepo.setStatus(id, status);
    SyncService.instance.syncNow();
  }

  Future<void> _toggle(Map<String, dynamic> item) async {
    await OrderRepo.setItemDone(item['id'] as String, item['done'] != true);
    SyncService.instance.syncNow();
  }

  bool _hasSpecial(Map<String, dynamic> order) => OrderRepo.liveItemsFor(order['id'] as String)
      .any((i) => ('${i['notes'] ?? ''}').trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final all = LocalStore.rows('orders');
        final cancelled = _cancelled();
        _maybeAlert(cancelled);
        final active = all
            .where((o) => o['status'] == 'new' || o['status'] == 'in_progress')
            .toList()
          ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
        _announce(active);
        final ready = all.where((o) => o['status'] == 'ready').toList()
          ..sort((a, b) => '${a['ready_at']}'.compareTo('${b['ready_at']}'));

        final shown = active.where((o) {
          switch (_filter) {
            case 'new':
              return o['status'] == 'new';
            case 'progress':
              return o['status'] == 'in_progress';
            case 'special':
              return _hasSpecial(o);
            default:
              return true;
          }
        }).toList();

        final done = all
            .where((o) => parseTime(o['ready_at']) != null && parseTime(o['sent_at']) != null)
            .toList();
        Duration? avg;
        if (done.isNotEmpty) {
          final total = done.fold<int>(
              0,
              (s, o) =>
                  s + parseTime(o['ready_at'])!.difference(parseTime(o['sent_at'])!).inSeconds);
          avg = Duration(seconds: total ~/ done.length);
        }

        return Container(
          color: _bg,
          child: Column(
            children: [
              _filters(active, avg),
              Expanded(
                child: shown.isEmpty
                    ? const Center(
                        child: Text('No orders waiting',
                            style: TextStyle(color: _soft, fontSize: 18)))
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [for (final o in shown) _orderCard(o)],
                        ),
                      ),
              ),
              _readyStrip(ready),
            ],
          ),
        );
      },
    );
  }

  Widget _filters(List<Map<String, dynamic>> active, Duration? avg) {
    final newCount = active.where((o) => o['status'] == 'new').length;
    final progress = active.where((o) => o['status'] == 'in_progress').length;
    final special = active.where(_hasSpecial).length;

    Widget chip(String key, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: _filter == key,
            onSelected: (_) => setState(() => _filter = key),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
          color: Color(0xFF15275C), border: Border(bottom: BorderSide(color: _line))),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip('all', 'All · ${active.length}'),
                  chip('new', 'New · $newCount'),
                  chip('progress', 'In progress · $progress'),
                  chip('special', 'Special requests · $special'),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: _soundOn ? 'Sound on for new orders (tap to turn off)' : 'Sound off (tap to turn on)',
            onPressed: () async {
              await LocalStore.setMeta('kitchen_sound', !_soundOn);
              if (_soundOn) playAlert(); // also lets the browser play sound from now on
              setState(() {});
            },
            icon: Icon(_soundOn ? Icons.volume_up : Icons.volume_off, color: _soundOn ? _ok : _soft),
          ),
          if (avg != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Average prep time',
                      style: TextStyle(color: _soft, fontSize: 11)),
                  Text(mmss(avg),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final id = o['id'] as String;
    final allItems = OrderRepo.itemsFor(id);
    final items = allItems.where((i) => i['voided'] != true).toList();
    final started = o['status'] == 'in_progress';
    final since = parseTime(o['sent_at']) ?? parseTime(o['created_at']) ?? DateTime.now();
    final elapsed = DateTime.now().difference(since);
    final mins = elapsed.inMinutes;
    final head = mins < 5 ? _green : (mins < 10 ? _amber : _red);
    final headText = mins >= 5 && mins < 10 ? const Color(0xFF1A1300) : Colors.white;
    final doneCount = items.where((i) => i['done'] == true).length;
    final type = {
          'eat_in': 'Eat in',
          'take_away': 'Take away',
          'delivery': 'Delivery'
        }[o['order_type']] ??
        '';
    final where = o['table_no'] != null ? '$type · Table ${o['table_no']}' : type;

    return SizedBox(
      width: 300,
      child: Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: head,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('#${o['order_ref']}',
                          style: TextStyle(
                              color: headText, fontSize: 21, fontWeight: FontWeight.w800)),
                      Text(where,
                          style: TextStyle(
                              color: headText, fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Text(mmss(elapsed),
                      style: TextStyle(
                          color: headText, fontSize: 26, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final i in allItems)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        onTap: i['voided'] == true ? null : () => _toggle(i),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: i['done'] == true ? _ok : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: i['done'] == true
                                            ? _ok
                                            : const Color(0xFF8FA0CC),
                                        width: 2),
                                  ),
                                  child: i['done'] == true
                                      ? const Icon(Icons.check, size: 18, color: Color(0xFF0E2A1B))
                                      : null,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text('${i['qty']}× ${i['name']}',
                                      style: TextStyle(
                                          color: i['voided'] == true
                                              ? _red
                                              : (i['done'] == true ? _soft : Colors.white),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 17,
                                          decoration: i['done'] == true || i['voided'] == true
                                              ? TextDecoration.lineThrough
                                              : null)),
                                ),
                                if (i['voided'] == true)
                                  const _Tag('REMOVED', _red, Colors.white)
                                else if (i['added_later'] == true)
                                  const _Tag('ADDED', _amber, Color(0xFF1A1300)),
                              ],
                            ),
                            if (('${i['notes'] ?? ''}').trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 36, top: 6),
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                      color: _amber, borderRadius: BorderRadius.circular(6)),
                                  child: Text('${i['notes']}'.toUpperCase(),
                                      style: const TextStyle(
                                          color: Color(0xFF1A1300),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: _line))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                          '${started ? 'In progress' : 'New'} · $doneCount of ${items.length} done',
                          style: const TextStyle(color: _soft, fontSize: 13)),
                      Text(
                          items.isEmpty
                              ? '0%'
                              : '${(100 * doneCount / items.length).round()}%',
                          style: const TextStyle(color: _soft, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: items.isEmpty ? 0 : doneCount / items.length,
                      minHeight: 6,
                      backgroundColor: _line,
                      color: _ok,
                    ),
                  ),
                  const SizedBox(height: 12),
                  started
                      ? FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: _ok, foregroundColor: const Color(0xFF0E2A1B)),
                          onPressed: () => _setStatus(id, 'ready'),
                          child: const Text('Mark ready'),
                        )
                      : FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFF4F6FB),
                              foregroundColor: _bg),
                          onPressed: () => _setStatus(id, 'in_progress'),
                          child: const Text('Start order'),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readyStrip(List<Map<String, dynamic>> ready) {
    return Container(
      height: 84,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
          color: Color(0xFF15275C), border: Border(top: BorderSide(color: _line))),
      child: Row(
        children: [
          const SizedBox(
            width: 110,
            child: Text('Ready for collection',
                style: TextStyle(color: _soft, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          Expanded(
            child: ready.isEmpty
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('None', style: TextStyle(color: _soft)))
                : ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final o in ready)
                        Container(
                          margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                          padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
                          decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _ok),
                          ),
                          child: Row(
                            children: [
                              Text('#${o['order_ref']}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 18)),
                              const SizedBox(width: 12),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 40),
                                    backgroundColor: const Color(0xFFF4F6FB),
                                    foregroundColor: _bg),
                                onPressed: () => _setStatus(o['id'] as String, 'collected'),
                                child: const Text('Collected'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.bg, this.fg);
  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}
