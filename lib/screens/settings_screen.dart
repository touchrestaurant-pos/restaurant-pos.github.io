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
    'invoice_prefix',
    'timezone',
  ];
  late final TextEditingController _tables;
  late final TextEditingController _vat;
  bool _cash = true;
  bool _card = true;
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
    if (!_cash && !_card) {
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
            const SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('EFT, SnapScan, card machine link'),
              subtitle: Text('Coming later'),
              value: false,
              onChanged: null,
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
            Center(child: _ReceiptPreview(values: _preview())),
          ],
        ),
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
                  child: Column(children: [payments, const SizedBox(height: 16), receipt]),
                ),
              ],
            );
          }
          return Column(children: [details, const SizedBox(height: 16), payments, const SizedBox(height: 16), receipt]);
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

  Map<String, String> _preview() => {
        for (final k in _textFields) k: _c[k]!.text.trim(),
      };
}

class _ReceiptPreview extends StatelessWidget {
  const _ReceiptPreview({required this.values});
  final Map<String, String> values;

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 12, color: Brand.muted);
    final name = values['company_name']!.isEmpty ? 'Your company' : values['company_name']!;
    final contact = [
      if (values['phone']!.isNotEmpty) 'Tel ${values['phone']}',
      if (values['vat_number']!.isNotEmpty) 'VAT ${values['vat_number']}',
    ].join(' · ');
    Widget row(String l, String r, {bool bold = false}) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l,
                  style: TextStyle(
                      fontSize: bold ? 14 : 12,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w400)),
              Text(r,
                  style: TextStyle(
                      fontSize: bold ? 14 : 12,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w400)),
            ],
          ),
        );
    return Container(
      width: 260,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Brand.border),
      ),
      child: Column(
        children: [
          const BrandMark(size: 44),
          const SizedBox(height: 8),
          Text(name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          if (values['address']!.isNotEmpty)
            Text(values['address']!, textAlign: TextAlign.center, style: small),
          if (contact.isNotEmpty) Text(contact, textAlign: TextAlign.center, style: small),
          const Divider(height: 20),
          row('2× Spicy Chicken Burger', '109.80'),
          row('1× Large Chips', '32.00'),
          const Divider(height: 20),
          row('Total', 'R141.80', bold: true),
          row('Paid: Cash', 'Change R8.20'),
          if (values['receipt_footer']!.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final l in footerLines(values['receipt_footer']!))
              l.kind == 'divider'
                  ? const Divider(height: 14)
                  : l.kind == 'gap'
                      ? const SizedBox(height: 6)
                      : SizedBox(
                          width: double.infinity,
                          child: Text(l.left,
                              textAlign: l.align < 0 ? TextAlign.left : (l.align > 0 ? TextAlign.right : TextAlign.center),
                              style: small.copyWith(
                                  fontSize: l.size + 4,
                                  fontWeight: l.bold ? FontWeight.w800 : null,
                                  fontStyle: l.italic ? FontStyle.italic : null))),
          ],
        ],
      ),
    );
  }
}
