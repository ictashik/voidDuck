import 'package:flutter/material.dart';

/// Pixel-grid legend shared by every robot frame variant (CLAUDE.md
/// "Rendering Approach": body/glasses are code-defined grids, not sprite
/// sheets).
class RobotPalette {
  static const empty = 0;
  static const body = 1;
  static const outline = 2;
  static const frame = 3;
  static const lens = 4;
  static const lensClosed = 5;
}

const List<Color?> _colors = [
  null, // empty -> transparent, shows the black stage through
  Color(0xFFB8C0C8), // body
  Color(0xFF33383E), // outline
  Color(0xFF1B1F24), // glasses frame
  Color(0xFF17323A), // lens, open (eye-dot sits on top of this)
  Color(0xFF1B1F24), // lens, closed/shutter — matches frame so it reads shut
];

const int gridCols = 12;
const int gridRows = 12;

/// Rest frame: boxy 8-bit body, antenna, glasses band with two lens cells
/// at row 5 (cols 3–4 and 7–8).
const List<List<int>> robotGrid = [
  [0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 2, 2, 0, 0, 0, 0, 0],
  [0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0],
  [0, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0],
  [0, 2, 3, 3, 3, 3, 3, 3, 3, 3, 2, 0],
  [0, 2, 3, 4, 4, 3, 3, 4, 4, 3, 2, 0],
  [0, 2, 3, 3, 3, 3, 3, 3, 3, 3, 2, 0],
  [0, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0],
  [0, 2, 1, 1, 2, 2, 2, 2, 1, 1, 2, 0],
  [0, 0, 2, 1, 1, 1, 1, 1, 1, 2, 0, 0],
  [0, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0],
  [0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0],
];

/// Blink frame: both lens cells swapped to the closed/shutter color. Built
/// once at load time rather than per-paint.
final List<List<int>> robotGridBlink = _withClosedLenses(robotGrid);

List<List<int>> _withClosedLenses(List<List<int>> base) {
  final g = base.map((row) => List<int>.from(row)).toList();
  for (final c in [3, 4, 7, 8]) {
    g[5][c] = RobotPalette.lensClosed;
  }
  return g;
}

class _LensSpot {
  const _LensSpot(this.row, this.col);
  final int row;
  final double col; // fractional — spans two grid cells
}

const _leftLens = _LensSpot(5, 3.5);
const _rightLens = _LensSpot(5, 7.5);

/// Paints one robot frame: the static/blink body+glasses grid, plus a
/// continuously-positioned eye-dot overlay per CLAUDE.md's rendering
/// approach and non-negotiable #6 — the eye-dot is the one element that is
/// never frame-snapped, driven straight from the spring-smoothed gaze
/// every paint call, independent of which body/glasses frame is active.
class RobotPainter extends CustomPainter {
  RobotPainter({
    required this.blink,
    required this.eyeX,
    required this.eyeY,
    required this.bodyOffset,
  });

  final bool blink;
  final double eyeX; // -1..1, spring-smoothed
  final double eyeY;
  final Offset bodyOffset; // small pixel nudge — "plus a small overall body/head offset" (spec 5)

  @override
  void paint(Canvas canvas, Size size) {
    final cell = (size.width / gridCols < size.height / gridRows)
        ? size.width / gridCols
        : size.height / gridRows;
    final gridWidth = cell * gridCols;
    final gridHeight = cell * gridRows;
    final origin = Offset(
      (size.width - gridWidth) / 2 + bodyOffset.dx,
      (size.height - gridHeight) / 2 + bodyOffset.dy,
    );

    final grid = blink ? robotGridBlink : robotGrid;
    final paint = Paint();
    for (var r = 0; r < gridRows; r++) {
      for (var c = 0; c < gridCols; c++) {
        final color = _colors[grid[r][c]];
        if (color == null) continue;
        paint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(
              origin.dx + c * cell, origin.dy + r * cell, cell, cell),
          paint,
        );
      }
    }

    if (!blink) {
      _drawEyeDot(canvas, origin, cell, _leftLens);
      _drawEyeDot(canvas, origin, cell, _rightLens);
    }
  }

  void _drawEyeDot(Canvas canvas, Offset origin, double cell, _LensSpot lens) {
    // Keep travel small — this should read as an eye looking around inside
    // the lens, not the whole dot wandering off it.
    final lensCenter = Offset(
      origin.dx + lens.col * cell,
      origin.dy + (lens.row + 0.5) * cell,
    );
    final travel = cell * 0.55;
    final dotCenter = lensCenter + Offset(eyeX * travel, eyeY * travel);
    canvas.drawCircle(
        dotCenter, cell * 0.28, Paint()..color = const Color(0xFF7FE7FF));
  }

  @override
  bool shouldRepaint(covariant RobotPainter old) =>
      old.blink != blink ||
      old.eyeX != eyeX ||
      old.eyeY != eyeY ||
      old.bodyOffset != bodyOffset;
}
