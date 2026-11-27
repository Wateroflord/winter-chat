import 'package:flutter/material.dart';

import '../theme.dart';
import '../util.dart';

/// Готовые цвета для быстрого выбора.
const quickColors = [
  Color(0xFF7FD8FF), Color(0xFF5B9DFF), Color(0xFF3D5AFE), Color(0xFF9C8CFF), Color(0xFFBE8CFF), Color(0xFFE040FB),
  Color(0xFFFF78AA), Color(0xFFFF5C5C), Color(0xFFFF9C7A), Color(0xFFFFAA5A), Color(0xFFFFD45A), Color(0xFFE8E15A),
  Color(0xFF6ED28C), Color(0xFF3DDCC8), Color(0xFF00BFA5), Color(0xFF8BC34A), Color(0xFFC4CCD8), Color(0xFFFFFFFF),
  Color(0xFF263238), Color(0xFF1B2A4A), Color(0xFF3A1F4A), Color(0xFF4A1F2A), Color(0xFF1F4A33), Color(0xFF000000),
];

/// Окно выбора цвета: готовые, ползунки оттенка/насыщенности/яркости и код #RRGGBB.
Future<Color?> pickColor(BuildContext context, {required Color initial, String title = 'Свой цвет'}) =>
    showDialog<Color>(context: context, builder: (_) => _ColorDialog(initial: initial, title: title));

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial, required this.title});
  final Color initial;
  final String title;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late HSVColor hsv = HSVColor.fromColor(widget.initial);
  late final hex = TextEditingController(text: colorToHex(widget.initial));

  Color get color => hsv.toColor();

  void _set(HSVColor v) {
    setState(() => hsv = v);
    hex.text = colorToHex(v.toColor());
  }

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  Widget _track(String label, List<Color> colors, double value, double max, void Function(double) onChanged) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: W.small),
          SizedBox(
            height: 34,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  height: 12,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), gradient: LinearGradient(colors: colors)),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                  ),
                  child: Slider(value: value, max: max, onChanged: onChanged),
                ),
              ],
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in quickColors)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _set(HSVColor.fromColor(c)),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.toARGB32() == color.toARGB32() ? W.text : W.border, width: c.toARGB32() == color.toARGB32() ? 3 : 1),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _track(
                'Оттенок',
                [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()],
                hsv.hue,
                360,
                (v) => _set(hsv.withHue(v)),
              ),
              _track(
                'Насыщенность',
                [hsv.withSaturation(0).toColor(), hsv.withSaturation(1).toColor()],
                hsv.saturation,
                1,
                (v) => _set(hsv.withSaturation(v)),
              ),
              _track(
                'Яркость',
                [Colors.black, hsv.withValue(1).toColor()],
                hsv.value,
                1,
                (v) => _set(hsv.withValue(v)),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12), border: Border.all(color: W.border)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: hex,
                      decoration: const InputDecoration(labelText: 'Код цвета', isDense: true),
                      onChanged: (v) {
                        final c = parseHexColor(v);
                        if (c != null) setState(() => hsv = HSVColor.fromColor(c));
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, color), child: const Text('Готово')),
      ],
    );
  }
}
