import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tuning/tuning.dart';

/// Live tuning panel (CLAUDE.md "in-app tuning panel"). Every knob that
/// affects feel is a slider here and persists across restarts via
/// SharedPreferences. A "copy current values" button dumps them as a Dart
/// snippet the human can paste back to me.
///
/// Sliders are grouped by section so the human isn't scrolling a 30-row list.
/// Adding a knob is purely data: extend [Tuning.specs] and it shows up here.
class TuningPanel extends StatefulWidget {
  const TuningPanel({super.key});

  @override
  State<TuningPanel> createState() => _TuningPanelState();
}

class _TuningPanelState extends State<TuningPanel> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: Tuning.userName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final specs = Tuning.specs;
    // Group keys by a section prefix derived from the key (everything before
    // the first underscore).
    final sections = <String, List<String>>{};
    for (final key in specs.keys) {
      final prefix = key.split('_').first;
      sections.putIfAbsent(prefix, () => []).add(key);
    }
    final orderedPrefixes = sections.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text(
              'TUNING',
              style: TextStyle(
                color: Color(0xFFE0E0E0),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _copyAll,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.copy, size: 12, color: Color(0xCCFFFFFF)),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                Tuning.reset();
                setState(() {});
              },
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.refresh, size: 12, color: Color(0xCCFFFFFF)),
              ),
            ),
          ],
        ),
        const Divider(height: 6, color: Color(0x44FFFFFF)),
        _sectionHeader('identity'),
        _nameField(),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children:
                  orderedPrefixes.expand((p) => [_sectionHeader(p), ...sections[p]!.map(_knob)]).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String p) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Text(
          p.toUpperCase(),
          style: const TextStyle(
            color: Color(0x99FFFFFF),
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.0,
          ),
        ),
      );

  Widget _nameField() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          const SizedBox(
            width: 110,
            child: Text(
              'Name',
              style: TextStyle(color: Color(0xBBFFFFFF), fontSize: 9),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _nameController,
              style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 11),
              cursorColor: const Color(0xFFFFFFFF),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0x44FFFFFF)),
                ),
              ),
              onChanged: (v) => Tuning.userName = v,
            ),
          ),
        ],
      ),
    );
  }

  Widget _knob(String key) {
    final spec = Tuning.specs[key]!;
    final value = Tuning.get(key);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              spec.label,
              style: const TextStyle(color: Color(0xBBFFFFFF), fontSize: 9),
            ),
          ),
          Expanded(
            child: Slider(
              min: spec.min,
              max: spec.max,
              divisions: spec.step == null
                  ? null
                  : ((spec.max - spec.min) / spec.step!).round(),
              value: value.clamp(spec.min, spec.max),
              onChanged: (v) {
                Tuning.set(key, v);
                setState(() {});
              },
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              spec.step != null && spec.step! >= 1
                  ? value.toStringAsFixed(0)
                  : value.toStringAsFixed(2),
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    final dump = Tuning.dumpAsDart();
    await Clipboard.setData(ClipboardData(text: dump));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tuning copied as Dart snippet'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }
}