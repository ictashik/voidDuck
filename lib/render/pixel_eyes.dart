import 'package:flutter/material.dart';

/// Eyelid states for one socket (CLAUDE.md "Rendering Approach"). `wide` is
/// visually identical to `open` at the grid level — its size comes entirely
/// from the pair-level dilate transform in [EyePairPainter], not the grid.
enum EyelidState { open, half, closed, squint, wide }

/// Color-index legend for the socket grid.
class _Ink {
  static const empty = 0; // transparent, shows the black stage through
  static const outline = 1;
  static const lit = 2; // open interior — pupil sits on top of this
  static const lid = 3; // lid-covered interior — reads as shut
}

const List<Color?> _colors = [
  null, // empty
  Color(0xFF33383E), // outline
  Color(0xFF17323A), // lit
  Color(0xFF1B1F24), // lid (matches outline tone -> reads shut)
];

const int socketCols = 8;
const int socketRows = 8;

/// Builds one 8x8 eye-socket grid: an oval outline with interior rows
/// (1–6) either lit or covered by a lid, depending on [lidRows].
List<List<int>> _buildSocketGrid(Set<int> lidRows) {
  List<int> interiorRow(int r) {
    final fill = lidRows.contains(r) ? _Ink.lid : _Ink.lit;
    return [_Ink.outline, fill, fill, fill, fill, fill, fill, _Ink.outline];
  }

  return [
    [_Ink.empty, _Ink.empty, _Ink.outline, _Ink.outline, _Ink.outline, _Ink.outline, _Ink.empty, _Ink.empty],
    for (var r = 1; r <= 6; r++) interiorRow(r),
    [_Ink.empty, _Ink.empty, _Ink.outline, _Ink.outline, _Ink.outline, _Ink.outline, _Ink.empty, _Ink.empty],
  ];
}

/// One grid per eyelid state. `squint` leaves rows 3–4 lit as a crescent
/// slit; `half` covers the top three rows (drowsy); `closed` covers all six.
final Map<EyelidState, List<List<int>>> eyeGrids = {
  EyelidState.open: _buildSocketGrid({}),
  EyelidState.wide: _buildSocketGrid({}),
  EyelidState.half: _buildSocketGrid({1, 2, 3}),
  EyelidState.closed: _buildSocketGrid({1, 2, 3, 4, 5, 6}),
  EyelidState.squint: _buildSocketGrid({1, 2, 5, 6}),
};

/// Paints the eye pair: two independently-stateable sockets (so a future
/// asynchronous blink/wink idle quirk doesn't need another rewrite) plus a
/// continuously-positioned pupil/highlight dot per socket. Pair-level
/// transforms (rotation, scale, offset) move both sockets together as one
/// rigid unit on top of whichever eyelid frame is active — CLAUDE.md
/// non-negotiable #6: the pupil position itself is never part of any
/// frame-swap, it's computed fresh every paint call.
class EyePairPainter extends CustomPainter {
  EyePairPainter({
    required this.leftState,
    required this.rightState,
    required this.pupilX,
    required this.pupilY,
    this.pairRotation = 0,
    this.pairScale = 1.0,
    this.pairOffset = Offset.zero,
  });

  final EyelidState leftState;
  final EyelidState rightState;
  final double pupilX; // -1..1, spring-smoothed
  final double pupilY;

  /// Rigid rotation of the whole eye pair around its midpoint — the
  /// head-tilt equivalent (spec Section 5, "Curiosity/Confusion").
  final double pairRotation;

  /// Uniform scale of the whole pair (socket size *and* the gap between
  /// them grow together) — the proximity/startle dilate, and where an
  /// idle-breathing pulse or debugging-listen nod modulate from.
  final double pairScale;

  /// Small translate for gaze-follow nudge / ambient jitter / breathing bob.
  final Offset pairOffset;

  static const double _gapCells = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final totalCols = socketCols * 2 + _gapCells;
    final cell = (size.width / totalCols < size.height / socketRows)
        ? size.width / totalCols
        : size.height / socketRows;
    final layoutWidth = cell * totalCols;
    final layoutHeight = cell * socketRows;
    final layoutOrigin = Offset(
      (size.width - layoutWidth) / 2,
      (size.height - layoutHeight) / 2,
    );
    final pairCenter = Offset(size.width / 2, size.height / 2);

    canvas.save();
    canvas.translate(pairCenter.dx + pairOffset.dx, pairCenter.dy + pairOffset.dy);
    canvas.rotate(pairRotation);
    canvas.scale(pairScale);
    canvas.translate(-pairCenter.dx, -pairCenter.dy);

    final leftOrigin = layoutOrigin;
    final rightOrigin = leftOrigin + Offset((socketCols + _gapCells) * cell, 0);

    _drawSocket(canvas, leftOrigin, cell, leftState);
    _drawSocket(canvas, rightOrigin, cell, rightState);

    canvas.restore();
  }

  void _drawSocket(
      Canvas canvas, Offset origin, double cell, EyelidState state) {
    final grid = eyeGrids[state]!;
    final paint = Paint();
    for (var r = 0; r < socketRows; r++) {
      for (var c = 0; c < socketCols; c++) {
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
    if (state != EyelidState.closed) {
      _drawPupil(canvas, origin, cell, state);
    }
  }

  void _drawPupil(
      Canvas canvas, Offset origin, double cell, EyelidState state) {
    final socketCenter = Offset(
      origin.dx + socketCols / 2 * cell,
      origin.dy + socketRows / 2 * cell,
    );
    // `squint` narrows the visible slit to the crescent rows — keep the
    // pupil's vertical travel tighter there so it doesn't paint over a lid.
    final verticalTravel =
        state == EyelidState.squint ? cell * 0.15 : cell * 0.9;
    const horizontalTravelFactor = 1.1;
    final dotCenter = socketCenter +
        Offset(pupilX * cell * horizontalTravelFactor, pupilY * verticalTravel);
    final radius = (state == EyelidState.wide ? 0.32 : 0.26) * cell;
    canvas.drawCircle(
        dotCenter, radius, Paint()..color = const Color(0xFF7FE7FF));
  }

  @override
  bool shouldRepaint(covariant EyePairPainter old) =>
      old.leftState != leftState ||
      old.rightState != rightState ||
      old.pupilX != pupilX ||
      old.pupilY != pupilY ||
      old.pairRotation != pairRotation ||
      old.pairScale != pairScale ||
      old.pairOffset != pairOffset;
}
