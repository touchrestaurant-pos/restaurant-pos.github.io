import 'package:flutter/material.dart';

import '../data/sync_service.dart';
import '../theme.dart';

/// Small status pill: online / offline and how many changes are waiting.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final s = SyncService.instance;
        final waiting = s.pendingCount;
        final colour = s.online ? Brand.green : Brand.amber;
        final label = s.online
            ? (waiting > 0 ? 'Online · $waiting waiting' : 'Online · synced')
            : 'Offline · $waiting waiting';
        return InkWell(
          onTap: s.syncNow,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 10, color: colour),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
      },
    );
  }
}
