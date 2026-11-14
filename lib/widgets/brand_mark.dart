import 'dart:io';

import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../theme.dart';

String companyDisplayName() {
  final c = companyRow();
  final name = (c?['trading_name'] ?? c?['company_name'] ?? '') as String;
  return name.trim().isEmpty ? 'RestoPOS' : name.trim();
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
  return letters.isEmpty ? 'R' : letters;
}

/// Gold square with the company logo, or its initials if no logo is set.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = (companyRow()?['logo_url'] ?? '') as String;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Brand.gold,
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: Text(
        initials(companyDisplayName()),
        style: TextStyle(
          color: Brand.navy,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    final image = url.startsWith('http')
        ? Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          )
        : Image.file(
            File(url),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.26),
      child: image,
    );
  }
}
