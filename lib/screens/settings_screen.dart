import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../receipt/receipt_service.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';
import 'admin_tools.dart';

/// Admin: company name, details, logo, VAT, receipt footer and payment methods.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _c = <String, TextEditingController>{};
  static const _textFields = [
    'company_name',
    'trading_name',
    'phone',
    'email',
    'vat_number',
    'reg_number',
    'address',
    'receipt_footer',
    'eft_details',
    'invoice_prefix',
    'timezone',
  ];
  late final TextEditingController _tables;
  late final TextEditingController _vat;
  bool _cash = true;
  bool _card = true;
  bool _eft = false;
  Map<String, dynamic> _style = {};
  bool _showVat = true;
  bool _showNotes = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    final row = companyRow() ?? {};
    for (final k in _textFields) {
      _c[k] = TextEditingController(text: '${row[k] ?? ''}');
    }
    _vat = TextEditingController(text: '${row['vat_rate'] ?? 15}');
    _tables = TextEditingController(text: '${row['table_count'] ?? 12}');
    if (_c['invoice_prefix']!.text.isEmpty) _c['invoice_prefix']!.text = 'INV';
    if (_c['timezone']!.text.isEmpty) _c['timezone']!.text = 'Africa/Johannesburg';
    _cash = row['accept_cash'] != false;
    _card = row['accept_card_manual'] != false;
    _eft = row['accept_eft'] == true;
    _style = row['receipt_style'] is Map ? Map<String, dynamic>.from(row['receipt_style'] as Map) : {};
    _showVat = row['show_vat_on_slip'] != false;
    _showNotes = row['show_notes_on_slip'] == true;
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _vat.dispose();
    _tables.dispose();
    super.dispose();
  }

  void _say(String text, {bool error = false}) =>
      setState(() {
        _message = text;
        _messageIsError = error;
      });

  Future<void> _save() async {
    final rate = double.tryParse(_vat.text.trim().replaceAll(',', '.'));
    if (rate == null || rate < 0 || rate > 100) {
      _say('VAT rate must be a number between 0 and 100.', error: true);
      return;
    }
    if (!_cash && !_card && !_eft) {
      _say('Keep at least one payment method switched on.', error: true);
      return;
    }
    final tables = int.tryParse(_tables.text.trim());
    if (tables == null || tables < 0 || tables > 200) {
      _say('Number of tables must be between 0 and 200.', error: true);
      return;
    }
    final fields = {
      for (final k in _textFields) k: _c[k]!.text.trim(),
      'vat_rate': rate,
      'accept_cash': _cash,
      'accept_card_manual': _card,
      'accept_eft': _eft,
      'receipt_style': _style,
      'show_vat_on_slip': _showVat,
      'show_notes_on_slip': _showNotes,
      'table_count': tables,
    };
    if (companyRow()?['id'] == 1) {
      await LocalStore.patch('company_settings', 1, fields);
    } else {
      await LocalStore.insert('company_settings', {'id': 1, ...fields});
    }
    await SyncService.instance.syncNow();
    _say('Saved. The name and logo update on every device within a minute.');
  }

  Future<void> _pickLogo() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      withData: true,
    );
    if (res == null) return;
    final file = res.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _say('Could not read that file.', error: true);
      return;
    }
    if (bytes.length > 2 * 1024 * 1024) {
      _say('That image is bigger than 2 MB. Choose a smaller one.', error: true);
      return;
    }
    final ext = (file.extension ?? 'png').toLowerCase();
    final mime = ext == 'jpg' || ext == 'jpeg'
        ? 'image/jpeg'
        : ext == 'webp'
            ? 'image/webp'
            : 'image/png';
    setState(() => _busy = true);
    try {
      final storage = Supabase.instance.client.storage.from('company-assets');
      final path = 'logo-${DateTime.now().millisecondsSinceEpoch}.$ext';
      await storage.uploadBinary(path, bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true));
      final url = storage.getPublicUrl(path);
      await LocalStore.upsert('company_settings', {
        ...(companyRow() ?? {'id': 1}),
        'id': 1,
        'logo_url': url,
      });
      await SyncService.instance.syncNow();
      _say('Logo uploaded.');
    } on StorageException catch (e) {
      _say('Upload failed: ${e.message}', error: true);
    } catch (_) {
      _say('Upload failed. Uploading a logo needs internet.', error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _removeLogo() async {
    await LocalStore.upsert('company_settings', {
      ...(companyRow() ?? {'id': 1}),
      'id': 1,
      'logo_url': null,
    });
    await SyncService.instance.syncNow();
    _say('Logo removed.');
  }

  Widget _field(String key, String label, {TextInputType? type}) => TextField(
        controller: _c[key],
        keyboardType: type,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: label, isDense: true),
      );

  /// Puts [tag] at the start of the line the cursor is on, or takes it off if it is already there.
  void _toggleTag(String tag, {List<String> replaces = const []}) {
    final c = _c['receipt_footer']!;
    final text = c.text;
    var pos = c.selection.isValid ? c.selection.baseOffset.clamp(0, text.length) : text.length;
    final start = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    var line = text.substring(start, end);
    final lead = RegExp(r'^\s*((\[(b|i|l|c|r|big|small|line)\])*)').firstMatch(line)!;
    var tags = lead.group(1)!;
    final body = line.substring(lead.end);
    if (tags.contains(tag)) {
      tags = tags.replaceAll(tag, '');
    } else {
      for (final r in replaces) {
        tags = tags.replaceAll(r, '');
      }
      tags += tag;
    }
    final next = text.replaceRange(start, end, '$tags$body');
    c.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: start + tags.length + body.length));
    setState(() {});
  }

  Widget _footerEditor() {
    Widget btn(String label, String tag, String tip, {List<String> replaces = const [], FontWeight? w, FontStyle? st}) => Tooltip(
          message: tip,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(40, 36), padding: const EdgeInsets.symmetric(horizontal: 10)),
            onPressed: () => _toggleTag(tag, replaces: replaces),
            child: Text(label, style: TextStyle(fontWeight: w, fontStyle: st)),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _c['receipt_footer'],
        minLines: 2,
        maxLines: 6,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
            labelText: 'Receipt footer message', isDense: true, alignLabelWithHint: true,
            helperText: 'One line per line on the slip. Click in a line, then use the buttons to style it.'),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        btn('B', '[b]', 'Bold', w: FontWeight.w900),
        btn('I', '[i]', 'Italic', st: FontStyle.italic),
        btn('Big', '[big]', 'Larger text', replaces: const ['[small]']),
        btn('Small', '[small]', 'Smaller text', replaces: const ['[big]']),
        btn('Left', '[l]', 'Align left', replaces: const ['[c]', '[r]']),
        btn('Centre', '[c]', 'Centre', replaces: const ['[l]', '[r]']),
        btn('Right', '[r]', 'Align right', replaces: const ['[l]', '[c]']),
        btn('Line', '[line]', 'Make this line a divider'),
      ]),
    ]);
  }

  void _setStyle(String k, Object v) => setState(() => _style = {..._style, k: v});

  /// A sample sale drawn with the real slip code, using what is typed on this page.
  ReceiptData _sampleReceipt() {
    final base = Map<String, dynamic>.from(companyRow() ?? {});
    for (final k in _textFields) {
      base[k] = _c[k]!.text.trim();
    }
    base['show_vat_on_slip'] = _showVat;
    base['receipt_style'] = _style;
    final now = DateTime.now().toUtc().toIso8601String();
    return ReceiptData(
      order: {
        'order_ref': '0042',
        'paid': true,
        'status': 'collected',
        'total': 141.80,
        'subtotal': 123.30,
        'vat': 18.50,
        'discount': 0,
        'invoice_no': 123,
        'created_at': now,
        'order_type': 'eat_in',
        'table_no': '4',
      },
      items: [
        {'qty': 2, 'name': 'Spicy Chicken Burger', 'unit_price': 54.90, 'vat_type': 'standard'},
        {'qty': 1, 'name': 'Large Chips', 'unit_price': 32.00, 'vat_type': 'standard'},
      ],
      payments: [
        {'method': 'cash', 'amount': 141.80, 'tip': 0, 'tendered': 150, 'change_given': 8.20, 'created_at': now},
      ],
      company: base,
    );
  }

  Widget _layoutEditor() {
    final st = ReceiptStyle.of({'receipt_style': _style});
    Widget label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)));
    Widget seg<T>(T value, List<(T, String)> opts, void Function(T) on) => SegmentedButton<T>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [for (final o in opts) ButtonSegment(value: o.$1, label: Text(o.$2))],
          selected: {value},
          onSelectionChanged: (v) => on(v.first),
        );
    final scale = const [0.85, 1.0, 1.15, 1.3].reduce((a, b) => (a - st.fontScale).abs() <= (b - st.fontScale).abs() ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Receipt layout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      const Text('The preview above changes as you pick. Remember to press Save changes.',
          style: TextStyle(color: Brand.muted, fontSize: 12)),
      label('Text size'),
      seg<double>(scale, const [(0.85, 'Small'), (1.0, 'Normal'), (1.15, 'Large'), (1.3, 'Extra large')],
          (v) => _setStyle('font_scale', v)),
      label('Logo'),
      seg<String>(st.logo, const [('hide', 'Hidden'), ('small', 'Small'), ('medium', 'Medium'), ('large', 'Large')],
          (v) => _setStyle('logo', v)),
      label('Name and contact lines'),
      seg<int>(st.headerAlign, const [(-1, 'Left'), (0, 'Centre'), (1, 'Right')], (v) => _setStyle('header_align', v)),
      label('Show at the top of the slip'),
      Wrap(spacing: 8, runSpacing: 6, children: [
        FilterChip(label: const Text('Address'), selected: st.showAddress, onSelected: (v) => _setStyle('show_address', v)),
        FilterChip(label: const Text('Phone'), selected: st.showPhone, onSelected: (v) => _setStyle('show_phone', v)),
        FilterChip(label: const Text('Email'), selected: st.showEmail, onSelected: (v) => _setStyle('show_email', v)),
        FilterChip(label: const Text('Company reg. no.'), selected: st.showReg, onSelected: (v) => _setStyle('show_reg', v)),
      ]),
      const SizedBox(height: 4),
      const Text('The VAT number shows whenever "Show our VAT number on the customer slip" is on, because a tax invoice must carry it.',
          style: TextStyle(color: Brand.muted, fontSize: 12)),
      label('Divider lines'),
      seg<String>(st.divider, const [('solid', 'Solid'), ('dashed', 'Dashed'), ('dotted', 'Dotted'), ('double', 'Double')],
          (v) => _setStyle('divider', v)),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(onPressed: () => setState(() => _style = {}), child: const Text('Reset layout to default')),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final hasLogo = ('${companyRow()?['logo_url'] ?? ''}').isNotEmpty;

    final details = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Company details',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Row(
              children: [
                const BrandMark(size: 80),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Company logo',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const Text('PNG, JPG or WEBP, square, under 2 MB.',
                          style: TextStyle(color: Brand.muted, fontSize: 12)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                backgroundColor: Brand.navy,
                                foregroundColor: Colors.white),
                            onPressed: _busy ? null : _pickLogo,
                            child: Text(_busy ? 'Uploading...' : 'Upload logo'),
                          ),
                          if (hasLogo)
                            OutlinedButton(
                                onPressed: _busy ? null : _removeLogo,
                                child: const Text('Remove')),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            LayoutBuilder(builder: (context, box) {
              final two = box.maxWidth > 520;
              final fields = <Widget>[
                _field('company_name', 'Company name'),
                _field('trading_name', 'Trading name (shown in the app)'),
                _field('phone', 'Phone', type: TextInputType.phone),
                _field('email', 'Email', type: TextInputType.emailAddress),
                _field('vat_number', 'VAT number'),
                _field('reg_number', 'Company registration no.'),
                TextField(
                  controller: _vat,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'VAT rate (%)', isDense: true),
                ),
                const TextField(
                  enabled: false,
                  decoration: InputDecoration(
                      labelText: 'Currency',
                      hintText: 'South African Rand (R)',
                      isDense: true),
                ),
              ];
              return Column(
                children: [
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final f in fields)
                        SizedBox(
                            width: two ? (box.maxWidth - 14) / 2 : box.maxWidth, child: f),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _field('address', 'Address'),
                  const SizedBox(height: 14),
                  _footerEditor(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show our VAT number on the customer slip'),
                    subtitle: const Text('Off: the slip says RECEIPT, not TAX INVOICE. A tax invoice must show your VAT number.'),
                    value: _showVat,
                    onChanged: (v) => setState(() => _showVat = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show kitchen notes on the customer slip'),
                    subtitle: const Text('Off: the slip shows only the special requests chosen for the item. The kitchen slip always shows everything.'),
                    value: _showNotes,
                    onChanged: (v) => setState(() => _showNotes = v),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );

    final payments = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Payment methods',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cash'),
              subtitle: const Text('Amount tendered and change due'),
              value: _cash,
              onChanged: (v) => setState(() => _cash = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Card'),
              subtitle: const Text('Taken on the card machine and recorded as a card payment'),
              value: _card,
              onChanged: (v) => setState(() => _card = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('EFT / bank transfer'),
              subtitle: const Text('The cashier records the bank reference. Shown on the slip and in the cash-up as a separate line, not in the till drawer.'),
              value: _eft,
              onChanged: (v) => setState(() => _eft = v),
            ),
            if (_eft)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TextField(
                  controller: _c['eft_details'],
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Banking details (shown to the cashier to read out)',
                    hintText: 'Bank, account name, account number, branch code',
                    isDense: true,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final receipt = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Receipt preview',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Center(child: SizedBox(width: 340, child: ReceiptPaper(r: _sampleReceipt()))),
          ],
        ),
      ),
    );

    final layout = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _layoutEditor(),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Company settings',
                  style: TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
              onPressed: _save,
              child: const Text('Save changes'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('Shown on the sign-in screen, the till, the kitchen screen and receipts.',
            style: TextStyle(color: Brand.muted)),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(_message!,
              style: TextStyle(
                  color: _messageIsError ? Brand.red : Brand.green,
                  fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, box) {
          if (box.maxWidth >= 980) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: details),
                const SizedBox(width: 16),
                SizedBox(
                  width: 400,
                  child: Column(children: [payments, const SizedBox(height: 16), receipt, const SizedBox(height: 16), layout]),
                ),
              ],
            );
          }
          return Column(children: [details, const SizedBox(height: 16), payments, const SizedBox(height: 16), receipt, const SizedBox(height: 16), layout]);
        }),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Till and invoices', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Wrap(spacing: 14, runSpacing: 14, children: [
                SizedBox(
                  width: 200,
                  child: TextField(
                      controller: _tables,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Number of tables', helperText: '0 hides the Tables view', isDense: true)),
                ),
                SizedBox(
                  width: 200,
                  child: _field('invoice_prefix', 'Invoice number prefix'),
                ),
                SizedBox(
                  width: 260,
                  child: _field('timezone', 'Time zone (for reports)'),
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                  'Paid orders get a sequential invoice number from the server (for example INV-000123). With a VAT number above, receipts are headed TAX INVOICE.',
                  style: TextStyle(color: Brand.muted, fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        const AdminTools(),
      ],
    );
  }
}
