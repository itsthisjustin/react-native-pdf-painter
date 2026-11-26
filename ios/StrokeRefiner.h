// StrokeRefiner — pure geometry for the two Apple Pencil refinements:
//
//   1. Shape recognition ("draw and hold"): decide whether a finished stroke
//      is a straight line, an arrow, a circle/ellipse, a rectangle or a
//      triangle, and produce the clean outline that replaces it.
//   2. Handwriting clean-up: a light, shrink-free smoothing of a stroke that
//      removes jitter but keeps corners, endpoints and the writer's hand.
//
// Nothing in here knows about PencilKit or UIKit: every function takes and
// returns plain point arrays, so the maths can be reasoned about (and
// compiled and tested) on its own. StrokeRefinementController is the glue
// that turns PKStroke into these arrays and back.
//
// Units. Stroke points live in the stroke's own coordinate space, which is
// zoomed and scaled on screen. Every absolute threshold is therefore given
// in *screen points* and multiplied by `unit` — the length, in stroke
// coordinates, of one screen point. Relative thresholds (fractions of the
// stroke's own size) need no unit.

#pragma once

#include <cstddef>
#include <vector>

namespace StrokeRefiner {

struct Vec {
    double x = 0;
    double y = 0;
};

// One sampled point of a stroke: position, time since the stroke began, and
// the PencilKit rendering attributes that travel with it.
struct Sample {
    double x = 0;
    double y = 0;
    double t = 0;
    double w = 0;
    double h = 0;
    double opacity = 1;
    double force = 1;
    double azimuth = 0;
    double altitude = 0;
    double secondaryScale = 1;
    double threshold = 0;
    double lateralJitter = 0;
};

// ---------------------------------------------------------------------------
// Hold detection
// ---------------------------------------------------------------------------

struct Hold {
    // How long the pen rested at the end of the stroke, in seconds.
    double duration = 0;
    // Timestamp (Sample::t) at which the rest began. Everything after it is
    // the pen sitting still and is not part of the drawn shape.
    double startTime = 0;
};

// Walks back from the last sample for as long as the path stays within
// `radius` of the final position. `samples` must be in time order.
Hold trailingHold(const std::vector<Sample> &samples, double radius);

// ---------------------------------------------------------------------------
// Shape recognition
// ---------------------------------------------------------------------------

enum class ShapeKind { None, Line, Arrow, Ellipse, Rectangle, Triangle };

struct Shape {
    ShapeKind kind = ShapeKind::None;
    // Line:      start, end
    // Arrow:     tail, tip, barb, barb
    // Rectangle: four corners in drawing order, starting nearest the pen-down
    // Triangle:  three corners in drawing order, starting nearest the pen-down
    std::vector<Vec> vertices;
    // Ellipse only: centre, semi-axes (radiusA along `rotation`), the angle
    // at which the user started and the direction they went round (+1 / -1).
    Vec center;
    double radiusA = 0;
    double radiusB = 0;
    double rotation = 0;
    double startAngle = 0;
    int direction = 1;
};

// Classifies a stroke (already cut at the start of the trailing hold).
// Returns kind None unless the stroke confidently matches one shape.
// With `linesOnly` only a straight line is considered (highlighter).
Shape recognizeShape(const std::vector<Vec> &points, double unit, bool linesOnly);

// Dense control points tracing a recognised shape, about `spacing` apart,
// with extra points packed against every corner and both ends so a B-spline
// through them keeps the corners sharp and the ends in place.
std::vector<Vec> shapeOutline(const Shape &shape, double spacing);

// ---------------------------------------------------------------------------
// Handwriting clean-up
// ---------------------------------------------------------------------------

struct SmoothResult {
    std::vector<Sample> samples;
    // Largest distance any point moved (stroke coordinates).
    double maxShift = 0;
    // Largest relative change of any point's width.
    double maxWidthChange = 0;
};

// Smooths a stroke sampled at a roughly even spacing. Endpoints and sharp
// corners are pinned, tight curves are left almost alone, no point moves by
// more than 0.8 screen points, and very short strokes come back untouched.
SmoothResult smoothStroke(const std::vector<Sample> &samples, double unit);

// Shortens a sampled stroke to the part drawn before `time`.
std::vector<Vec> pointsBefore(const std::vector<Sample> &samples, double time);

} // namespace StrokeRefiner
