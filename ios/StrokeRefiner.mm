#include "StrokeRefiner.h"

#include <algorithm>
#include <cmath>
#include <limits>

// Pure C++ on purpose (see StrokeRefiner.h): no Foundation, UIKit or
// PencilKit in this file.

namespace StrokeRefiner {
namespace {

// ===========================================================================
// Thresholds
// ===========================================================================
// Lengths marked "pt" are screen points and get multiplied by `unit`.
// Everything else is a fraction of the stroke's own size, so recognition
// behaves the same at every zoom level.

// --- Size gate: marks in roll-and-write boxes (an X or tick in a 10 pt box)
// must never be "recognised", so anything small is left alone.
const double kMinPathLengthPt = 36.0;   // total ink length
const double kMinDiagonalPt = 24.0;     // bounding-box diagonal

// --- Straight line
const double kLineMinLengthPt = 30.0;
const double kLineMaxLengthRatio = 1.10;   // path length / chord
const double kLineMaxDeviation = 0.055;    // furthest point from the chord, / chord
const double kLineRmsDeviation = 0.030;    // rms distance from the chord, / chord

// --- Arrow: a straight shaft, then a two-sided head drawn back from the tip
const double kArrowMinShaftPt = 30.0;
const double kArrowShaftLengthRatio = 1.08;   // shaft path / shaft chord
const double kArrowShaftDeviation = 0.06;     // / shaft length
const double kArrowHeadMinPath = 0.20;        // head ink, / shaft length
const double kArrowHeadMaxPath = 1.80;
const double kArrowBarbMinLength = 0.10;      // / shaft length
const double kArrowBarbMaxLength = 0.60;
const double kArrowBarbMinSide = 0.05;        // each barb's reach to its side, / shaft
const double kArrowBarbBalance = 0.40;        // shorter barb / longer barb
const double kArrowBarbMinAngle = 15.0;       // degrees back from the shaft
const double kArrowBarbMaxAngle = 75.0;
const double kArrowOvershoot = 0.10;          // head may pass the tip by this, / shaft
const double kArrowHeadFit = 0.30;            // head ink to ideal head, / barb length
const double kArrowEndAtBarb = 0.35;          // stroke must end at a barb tip, / barb length
const double kArrowCleanMinAngle = 22.0;      // clean head is drawn within these
const double kArrowCleanMaxAngle = 42.0;

// --- Closed shapes (ellipse, rectangle, triangle)
const double kClosedRawGap = 0.20;        // start-end gap / path length, before trimming
const double kClosedGap = 0.12;           // same, after trimming the overlap
const double kClosedMinKept = 0.75;       // trimming may not discard more than 25 %
const double kClosedMinTurn = 1.5;        // total turning, in units of pi (one loop = 2)
const double kClosedMaxTurn = 2.5;
const double kClosedMinConvexity = 0.85;  // enclosed area / convex hull area

const double kEllipseRms = 0.060;         // rms of |r - 1| on the unit ellipse
const double kEllipseMax = 0.150;
const double kEllipseMinAspect = 0.20;    // minor / major
const double kEllipseCircleAspect = 0.90; // rounder than this becomes a circle
const double kEllipseAxisSnapDeg = 8.0;   // nearly upright ellipses become upright

const double kPolygonRms = 0.040;         // rms distance to the outline / shape size
const double kPolygonMax = 0.100;
const double kRectMinAspect = 0.12;       // short side / long side
const double kRectSideAngleDeg = 12.0;    // each side vs. the rectangle's axes
const double kRectAxisSnapDeg = 6.0;      // nearly upright rectangles become upright
const double kRectSquareTolerance = 0.10; // sides this close become a square
const double kTriangleMinAngleDeg = 20.0;

// --- Handwriting clean-up
const double kSmoothMinLengthPt = 8.0;     // dots and ticks shorter than this are untouched
const double kSmoothArmPt = 2.5;           // arm length used to measure turning
const double kSmoothCornerDeg = 45.0;      // sharper turns than this are pinned
const double kSmoothFadeDeg = 60.0;        // smoothing fades to nothing by this turn
const int kSmoothIterations = 8;           // Taubin lambda/mu passes
const double kSmoothLambda = 0.50;
const double kSmoothMu = -0.52;
const double kSmoothMaxShiftPt = 0.8;      // no point moves further than this
const int kSmoothWidthWindow = 2;          // +/- samples averaged for width
const double kSmoothWidthBlend = 0.5;      // how far width moves towards that average

const double kPi = 3.14159265358979323846;

// ===========================================================================
// Small vector helpers
// ===========================================================================

inline Vec make(double x, double y) { Vec v; v.x = x; v.y = y; return v; }
inline Vec operator+(Vec a, Vec b) { return make(a.x + b.x, a.y + b.y); }
inline Vec operator-(Vec a, Vec b) { return make(a.x - b.x, a.y - b.y); }
inline Vec operator*(Vec a, double s) { return make(a.x * s, a.y * s); }
inline double dot(Vec a, Vec b) { return a.x * b.x + a.y * b.y; }
inline double cross(Vec a, Vec b) { return a.x * b.y - a.y * b.x; }
inline double length(Vec a) { return std::hypot(a.x, a.y); }
inline double dist(Vec a, Vec b) { return length(a - b); }
inline double radians(double degrees) { return degrees * kPi / 180.0; }

double pathLength(const std::vector<Vec> &p) {
    double total = 0;
    for (size_t i = 1; i < p.size(); i++) total += dist(p[i - 1], p[i]);
    return total;
}

// `count` points evenly spaced along the polyline, both ends included.
std::vector<Vec> resample(const std::vector<Vec> &p, int count) {
    std::vector<Vec> out;
    if (p.empty() || count < 2) return out;
    double total = pathLength(p);
    if (total <= 0) return std::vector<Vec>(count, p.front());
    out.reserve(count);
    out.push_back(p.front());
    double step = total / (count - 1);
    double walked = 0;
    double target = step;
    for (size_t i = 1; i < p.size() && (int)out.size() < count - 1; i++) {
        double seg = dist(p[i - 1], p[i]);
        while (seg > 0 && walked + seg >= target && (int)out.size() < count - 1) {
            double f = (target - walked) / seg;
            out.push_back(p[i - 1] + (p[i] - p[i - 1]) * f);
            target += step;
        }
        walked += seg;
    }
    while ((int)out.size() < count) out.push_back(p.back());
    return out;
}

double distToSegment(Vec p, Vec a, Vec b) {
    Vec ab = b - a;
    double len2 = dot(ab, ab);
    if (len2 <= 0) return dist(p, a);
    double t = std::max(0.0, std::min(1.0, dot(p - a, ab) / len2));
    return dist(p, a + ab * t);
}

// Distance from `p` to the outline of a closed polygon.
double distToOutline(Vec p, const std::vector<Vec> &poly) {
    double best = std::numeric_limits<double>::max();
    for (size_t i = 0; i < poly.size(); i++) {
        best = std::min(best, distToSegment(p, poly[i], poly[(i + 1) % poly.size()]));
    }
    return best;
}

// Signed area of a closed polygon (positive = counter-clockwise in a y-up frame).
double signedArea(const std::vector<Vec> &poly) {
    double sum = 0;
    for (size_t i = 0; i < poly.size(); i++) sum += cross(poly[i], poly[(i + 1) % poly.size()]);
    return sum / 2;
}

// Convex hull (Andrew's monotone chain), counter-clockwise, no repeated point.
std::vector<Vec> convexHull(std::vector<Vec> p) {
    std::sort(p.begin(), p.end(), [](Vec a, Vec b) { return a.x < b.x || (a.x == b.x && a.y < b.y); });
    if (p.size() < 3) return p;
    std::vector<Vec> hull(2 * p.size());
    size_t k = 0;
    for (size_t i = 0; i < p.size(); i++) {
        while (k >= 2 && cross(hull[k - 1] - hull[k - 2], p[i] - hull[k - 2]) <= 0) k--;
        hull[k++] = p[i];
    }
    for (size_t i = p.size() - 1, lower = k + 1; i-- > 0;) {
        while (k >= lower && cross(hull[k - 1] - hull[k - 2], p[i] - hull[k - 2]) <= 0) k--;
        hull[k++] = p[i];
    }
    hull.resize(k - 1);
    return hull;
}

// Direction (angle in radians, modulo pi) of the total-least-squares line
// through `p`, and its centroid.
double fitLineAngle(const std::vector<Vec> &p, Vec *centroid) {
    Vec c = make(0, 0);
    for (Vec v : p) c = c + v;
    c = c * (1.0 / p.size());
    double sxx = 0, syy = 0, sxy = 0;
    for (Vec v : p) {
        sxx += (v.x - c.x) * (v.x - c.x);
        syy += (v.y - c.y) * (v.y - c.y);
        sxy += (v.x - c.x) * (v.y - c.y);
    }
    if (centroid) *centroid = c;
    return 0.5 * std::atan2(2 * sxy, sxx - syy);
}

// Smallest difference between two angles that repeat every `period` radians.
double angleDifference(double a, double b, double period) {
    double d = std::fmod(a - b, period);
    if (d > period / 2) d -= period;
    if (d < -period / 2) d += period;
    return std::fabs(d);
}

// A candidate shape with how well the stroke fits it. `score` is the worse
// of (rms / allowed rms) and (max / allowed max): below 1 means accepted,
// and the lowest score among accepted candidates wins.
struct Candidate {
    Shape shape;
    double score = std::numeric_limits<double>::max();
};

double fitScore(double rms, double maxError, double rmsLimit, double maxLimit) {
    return std::max(rms / rmsLimit, maxError / maxLimit);
}

// Rotates a closed polygon's vertex list so it starts at the corner nearest
// `start` and runs in the direction the user drew (`direction` = sign of the
// stroke's signed area).
void orderLikeStroke(std::vector<Vec> &poly, Vec start, double direction) {
    if (signedArea(poly) * direction < 0) std::reverse(poly.begin(), poly.end());
    size_t nearest = 0;
    for (size_t i = 1; i < poly.size(); i++) {
        if (dist(poly[i], start) < dist(poly[nearest], start)) nearest = i;
    }
    std::rotate(poly.begin(), poly.begin() + nearest, poly.end());
}

// ===========================================================================
// Line
// ===========================================================================
// A stroke is a line when it never strays far from the straight chord
// between its two ends and does not double back on itself.

bool matchLine(const std::vector<Vec> &p, double total, double unit, Shape *out) {
    Vec a = p.front(), b = p.back();
    double chord = dist(a, b);
    if (chord < kLineMinLengthPt * unit) return false;
    if (total > kLineMaxLengthRatio * chord) return false;
    double maxDev = 0, sumSq = 0;
    for (Vec v : p) {
        double d = distToSegment(v, a, b);
        maxDev = std::max(maxDev, d);
        sumSq += d * d;
    }
    if (maxDev > kLineMaxDeviation * chord) return false;
    if (std::sqrt(sumSq / p.size()) > kLineRmsDeviation * chord) return false;
    out->kind = ShapeKind::Line;
    out->vertices = {a, b};
    return true;
}

// ===========================================================================
// Arrow
// ===========================================================================
// One stroke: a straight shaft from the tail to the tip, then a head drawn
// back from the tip — either tip > barb > tip > other barb, or tip > barb >
// straight across to the other barb. The tip is the point furthest from the
// pen-down (both barbs lie behind it). The head is then judged in the
// shaft's own frame: it must reach to both sides of the shaft, lean back at
// a sensible angle, stay close to an ideal two-barb head, and the stroke
// must end at a barb tip. A hook to one side only (a tick, a "7", a "1") is
// not an arrow.

bool matchArrow(const std::vector<Vec> &p, double total, double unit, Shape *out) {
    int n = (int)p.size();
    Vec tail = p.front();
    int tipIndex = 0;
    for (int i = 1; i < n; i++) {
        if (dist(tail, p[i]) > dist(tail, p[tipIndex])) tipIndex = i;
    }
    Vec tip = p[tipIndex];
    double shaft = dist(tail, tip);
    if (shaft < kArrowMinShaftPt * unit) return false;
    if (tipIndex < n * 3 / 10 || tipIndex > n - 8) return false;

    double shaftPath = 0, shaftDev = 0;
    for (int i = 1; i <= tipIndex; i++) {
        shaftPath += dist(p[i - 1], p[i]);
        shaftDev = std::max(shaftDev, distToSegment(p[i], tail, tip));
    }
    if (shaftPath > kArrowShaftLengthRatio * shaft) return false;
    if (shaftDev > kArrowShaftDeviation * shaft) return false;
    double headPath = total - shaftPath;
    if (headPath < kArrowHeadMinPath * shaft || headPath > kArrowHeadMaxPath * shaft) return false;

    // Head points in the shaft frame: x forward along the shaft, y to its side.
    Vec forward = (tip - tail) * (1.0 / shaft);
    Vec side = make(-forward.y, forward.x);
    int leftIndex = tipIndex, rightIndex = tipIndex;
    double leftReach = 0, rightReach = 0, furthestForward = 0;
    for (int i = tipIndex; i < n; i++) {
        double hx = dot(p[i] - tip, forward);
        double hy = dot(p[i] - tip, side);
        furthestForward = std::max(furthestForward, hx);
        if (hy > leftReach) { leftReach = hy; leftIndex = i; }
        if (-hy > rightReach) { rightReach = -hy; rightIndex = i; }
    }
    if (furthestForward > kArrowOvershoot * shaft) return false;
    if (leftReach < kArrowBarbMinSide * shaft || rightReach < kArrowBarbMinSide * shaft) return false;

    Vec left = p[leftIndex], right = p[rightIndex];
    double leftLength = dist(left, tip), rightLength = dist(right, tip);
    double shorter = std::min(leftLength, rightLength), longer = std::max(leftLength, rightLength);
    if (shorter < kArrowBarbMinLength * shaft || longer > kArrowBarbMaxLength * shaft) return false;
    if (shorter < kArrowBarbBalance * longer) return false;
    double leftAngle = std::atan2(leftReach, -dot(left - tip, forward));
    double rightAngle = std::atan2(rightReach, -dot(right - tip, forward));
    double minAngle = radians(kArrowBarbMinAngle), maxAngle = radians(kArrowBarbMaxAngle);
    if (leftAngle < minAngle || leftAngle > maxAngle) return false;
    if (rightAngle < minAngle || rightAngle > maxAngle) return false;

    double barb = (leftLength + rightLength) / 2;
    for (int i = tipIndex; i < n; i++) {
        double d = std::min(distToSegment(p[i], tip, left),
                            std::min(distToSegment(p[i], tip, right), distToSegment(p[i], left, right)));
        if (d > kArrowHeadFit * barb) return false;
    }
    bool leftFirst = leftIndex < rightIndex;
    if (dist(p.back(), leftFirst ? right : left) > kArrowEndAtBarb * barb) return false;

    // Clean head: symmetric barbs of the average length and angle.
    double angle = std::max(radians(kArrowCleanMinAngle),
                            std::min(radians(kArrowCleanMaxAngle), (leftAngle + rightAngle) / 2));
    Vec back = forward * (-std::cos(angle) * barb);
    Vec across = side * (std::sin(angle) * barb);
    Vec cleanLeft = tip + back + across, cleanRight = tip + back - across;
    out->kind = ShapeKind::Arrow;
    out->vertices = {tail, tip, leftFirst ? cleanLeft : cleanRight, leftFirst ? cleanRight : cleanLeft};
    return true;
}

// ===========================================================================
// Closed shapes
// ===========================================================================

// Turns a stroke whose ends meet into a loop. People overshoot the start or
// stop a little short of it, so the closest pair of points between the first
// and last fifth of the stroke becomes the join and whatever lies outside it
// is dropped. Returns false when the stroke is not closed.
bool closeLoop(const std::vector<Vec> &p, double total, std::vector<Vec> *loop) {
    if (dist(p.front(), p.back()) > kClosedRawGap * total) return false;
    const int n = 128;
    std::vector<Vec> r = resample(p, n);
    int bestI = 0, bestJ = n - 1;
    double best = dist(r[0], r[n - 1]);
    for (int i = 0; i < n / 5; i++) {
        for (int j = n - n / 5; j < n; j++) {
            double d = dist(r[i], r[j]);
            if (d < best) { best = d; bestI = i; bestJ = j; }
        }
    }
    std::vector<Vec> trimmed(r.begin() + bestI, r.begin() + bestJ + 1);
    double kept = pathLength(trimmed);
    if (kept < kClosedMinKept * total) return false;
    if (best > kClosedGap * kept) return false;
    *loop = resample(trimmed, 96);
    return true;
}

// Total turning of the closed polygon in units of pi: 2 for any single loop,
// 0 for a figure of eight, 4 for a double loop.
double totalTurning(const std::vector<Vec> &loop) {
    std::vector<Vec> coarse;
    for (size_t i = 0; i < loop.size(); i += 2) coarse.push_back(loop[i]);
    size_t n = coarse.size();
    double sum = 0;
    for (size_t i = 0; i < n; i++) {
        Vec a = coarse[(i + 1) % n] - coarse[i];
        Vec b = coarse[(i + 2) % n] - coarse[(i + 1) % n];
        sum += std::atan2(cross(a, b), dot(a, b));
    }
    return std::fabs(sum) / kPi;
}

// --- Ellipse ---------------------------------------------------------------
// The ellipse with the same area moments as the region the stroke encloses
// (for a true ellipse those moments give its centre, axes and tilt exactly).
// Fit error is how far each point is from radius 1 after mapping that
// ellipse onto the unit circle. A square scores about 0.10 rms / 0.22 max
// here, well outside the limits.

Candidate fitEllipse(const std::vector<Vec> &loop, double area) {
    Candidate c;
    size_t n = loop.size();
    Vec origin = loop[0];
    double a2 = 0, cx = 0, cy = 0, ixx = 0, iyy = 0, ixy = 0;
    for (size_t i = 0; i < n; i++) {
        Vec p = loop[i] - origin, q = loop[(i + 1) % n] - origin;
        double w = cross(p, q);
        a2 += w;
        cx += (p.x + q.x) * w;
        cy += (p.y + q.y) * w;
        ixx += (p.x * p.x + p.x * q.x + q.x * q.x) * w;
        iyy += (p.y * p.y + p.y * q.y + q.y * q.y) * w;
        ixy += (p.x * q.y + 2 * p.x * p.y + 2 * q.x * q.y + q.x * p.y) * w;
    }
    double polyArea = a2 / 2;
    if (std::fabs(polyArea) < 1e-9) return c;
    cx /= 6 * polyArea;
    cy /= 6 * polyArea;
    double mxx = ixx / (12 * polyArea) - cx * cx;
    double myy = iyy / (12 * polyArea) - cy * cy;
    double mxy = ixy / (24 * polyArea) - cx * cy;
    double mean = (mxx + myy) / 2;
    double spread = std::sqrt((mxx - myy) * (mxx - myy) / 4 + mxy * mxy);
    if (mean - spread <= 0) return c;
    double major = 2 * std::sqrt(mean + spread);
    double minor = 2 * std::sqrt(mean - spread);
    double rotation = 0.5 * std::atan2(2 * mxy, mxx - myy);
    if (minor < kEllipseMinAspect * major) return c;

    Vec center = make(origin.x + cx, origin.y + cy);
    Vec axisA = make(std::cos(rotation), std::sin(rotation));
    Vec axisB = make(-axisA.y, axisA.x);
    double sumSq = 0, maxError = 0;
    for (Vec v : loop) {
        double u = dot(v - center, axisA) / major, w = dot(v - center, axisB) / minor;
        double e = std::fabs(std::hypot(u, w) - 1);
        sumSq += e * e;
        maxError = std::max(maxError, e);
    }
    c.score = fitScore(std::sqrt(sumSq / n), maxError, kEllipseRms, kEllipseMax);

    if (minor >= kEllipseCircleAspect * major) {
        major = minor = std::sqrt(major * minor);
        rotation = 0;
    } else if (angleDifference(rotation, 0, kPi / 2) < radians(kEllipseAxisSnapDeg)) {
        rotation = std::round(rotation / (kPi / 2)) * (kPi / 2);
    }
    axisA = make(std::cos(rotation), std::sin(rotation));
    axisB = make(-axisA.y, axisA.x);
    c.shape.kind = ShapeKind::Ellipse;
    c.shape.center = center;
    c.shape.radiusA = major;
    c.shape.radiusB = minor;
    c.shape.rotation = rotation;
    c.shape.startAngle = std::atan2(dot(loop[0] - center, axisB) / minor, dot(loop[0] - center, axisA) / major);
    c.shape.direction = area >= 0 ? 1 : -1;
    return c;
}

// --- Rectangle -------------------------------------------------------------
// 1. Rough orientation: the minimum-area bounding rectangle of the hull.
// 2. Each point is assigned to its nearest side; a line is fitted through
//    each side's points (corner regions excluded) and the four directions are
//    averaged modulo 90 degrees into the rectangle's tilt. A side that
//    disagrees with that tilt means a trapezoid or parallelogram: rejected.
// 3. In the tilted frame each side sits at the mean position of its points,
//    which undoes the outward bias of a bounding box around wobbly ink.
// Fit error is the distance from every point to the resulting outline.

Candidate fitRectangle(const std::vector<Vec> &loop, const std::vector<Vec> &hull, double area) {
    Candidate c;
    // 1. Minimum-area bounding rectangle over the hull's edge directions.
    double bestArea = std::numeric_limits<double>::max(), theta = 0;
    for (size_t i = 0; i < hull.size(); i++) {
        Vec e = hull[(i + 1) % hull.size()] - hull[i];
        if (length(e) <= 0) continue;
        Vec u = e * (1.0 / length(e)), v = make(-u.y, u.x);
        double minU = 1e300, maxU = -1e300, minV = 1e300, maxV = -1e300;
        for (Vec h : hull) {
            minU = std::min(minU, dot(h, u)); maxU = std::max(maxU, dot(h, u));
            minV = std::min(minV, dot(h, v)); maxV = std::max(maxV, dot(h, v));
        }
        double boxArea = (maxU - minU) * (maxV - minV);
        if (boxArea < bestArea) { bestArea = boxArea; theta = std::atan2(u.y, u.x); }
    }

    // Sides of the bounding box in the frame tilted by `angle`:
    // 0 = low u, 1 = high u, 2 = low v, 3 = high v. Points near a corner
    // (outer quarter of the side) belong to no side.
    struct Frame { Vec u, v; double lo[2], hi[2]; };
    auto frameFor = [&](double angle) {
        Frame f;
        f.u = make(std::cos(angle), std::sin(angle));
        f.v = make(-f.u.y, f.u.x);
        f.lo[0] = f.lo[1] = 1e300;
        f.hi[0] = f.hi[1] = -1e300;
        for (Vec p : loop) {
            f.lo[0] = std::min(f.lo[0], dot(p, f.u)); f.hi[0] = std::max(f.hi[0], dot(p, f.u));
            f.lo[1] = std::min(f.lo[1], dot(p, f.v)); f.hi[1] = std::max(f.hi[1], dot(p, f.v));
        }
        return f;
    };
    auto sideOf = [](const Frame &f, Vec p) {
        double pu = dot(p, f.u), pv = dot(p, f.v);
        double d[4] = {pu - f.lo[0], f.hi[0] - pu, pv - f.lo[1], f.hi[1] - pv};
        int side = 0;
        for (int k = 1; k < 4; k++) if (d[k] < d[side]) side = k;
        // Position along the side, 0..1; ignore the corner regions.
        double along = side < 2 ? (pv - f.lo[1]) / std::max(1e-9, f.hi[1] - f.lo[1])
                                : (pu - f.lo[0]) / std::max(1e-9, f.hi[0] - f.lo[0]);
        return (along < 0.125 || along > 0.875) ? -1 : side;
    };

    // 2. Tilt from the four fitted side lines.
    Frame rough = frameFor(theta);
    std::vector<Vec> sidePoints[4];
    for (Vec p : loop) {
        int side = sideOf(rough, p);
        if (side >= 0) sidePoints[side].push_back(p);
    }
    // (The short sides of a thin box hold too few points for a direction of
    // their own; they neither vote nor get checked.)
    double sumCos = 0, sumSin = 0, sideAngle[4];
    bool votes[4];
    int voters = 0;
    for (int k = 0; k < 4; k++) {
        if (sidePoints[k].size() < 2) return c;   // a side with no ink: not a rectangle
        votes[k] = sidePoints[k].size() >= 6;
        if (!votes[k]) continue;
        voters++;
        sideAngle[k] = fitLineAngle(sidePoints[k], nullptr);
        sumCos += sidePoints[k].size() * std::cos(4 * sideAngle[k]);
        sumSin += sidePoints[k].size() * std::sin(4 * sideAngle[k]);
    }
    if (voters < 2) return c;
    theta = std::atan2(sumSin, sumCos) / 4;
    for (int k = 0; k < 4; k++) {
        if (votes[k] && angleDifference(sideAngle[k], theta, kPi / 2) > radians(kRectSideAngleDeg)) return c;
    }
    if (angleDifference(theta, 0, kPi / 2) < radians(kRectAxisSnapDeg)) theta = 0;

    // 3. Side positions in the final frame.
    Frame f = frameFor(theta);
    double sum[4] = {0, 0, 0, 0};
    int count[4] = {0, 0, 0, 0};
    for (Vec p : loop) {
        int side = sideOf(f, p);
        if (side < 0) continue;
        sum[side] += side < 2 ? dot(p, f.u) : dot(p, f.v);
        count[side]++;
    }
    for (int k = 0; k < 4; k++) if (count[k] < 2) return c;
    double loU = sum[0] / count[0], hiU = sum[1] / count[1];
    double loV = sum[2] / count[2], hiV = sum[3] / count[3];
    double width = hiU - loU, height = hiV - loV;
    if (width <= 0 || height <= 0) return c;
    double shortSide = std::min(width, height), longSide = std::max(width, height);
    if (shortSide < kRectMinAspect * longSide) return c;

    auto corner = [&](double pu, double pv) { return f.u * pu + f.v * pv; };
    std::vector<Vec> poly = {corner(loU, loV), corner(hiU, loV), corner(hiU, hiV), corner(loU, hiV)};
    double sumSq = 0, maxError = 0;
    for (Vec p : loop) {
        double d = distToOutline(p, poly);
        sumSq += d * d;
        maxError = std::max(maxError, d);
    }
    // Errors are relative to the short side, but a long thin box is not held
    // to a tighter standard than a third of its length.
    double size = std::max(shortSide, 0.3 * longSide);
    c.score = fitScore(std::sqrt(sumSq / loop.size()) / size, maxError / size, kPolygonRms, kPolygonMax);

    if (longSide - shortSide <= kRectSquareTolerance * longSide) {
        double centerU = (loU + hiU) / 2, centerV = (loV + hiV) / 2, half = (width + height) / 4;
        poly = {corner(centerU - half, centerV - half), corner(centerU + half, centerV - half),
                corner(centerU + half, centerV + half), corner(centerU - half, centerV + half)};
    }
    orderLikeStroke(poly, loop[0], area >= 0 ? 1 : -1);
    c.shape.kind = ShapeKind::Rectangle;
    c.shape.vertices = poly;
    return c;
}

// --- Triangle --------------------------------------------------------------
// The three hull points spanning the largest triangle are the rough corners.
// Each side is then re-fitted as a line through the points nearest to it
// (corner regions excluded) and the corners become the intersections of
// those lines, so wobble and rounded corners do not shrink the result.

bool intersectLines(Vec p, double angleP, Vec q, double angleQ, Vec *out) {
    Vec d1 = make(std::cos(angleP), std::sin(angleP)), d2 = make(std::cos(angleQ), std::sin(angleQ));
    double denom = cross(d1, d2);
    if (std::fabs(denom) < 1e-6) return false;
    double t = cross(q - p, d2) / denom;
    *out = p + d1 * t;
    return true;
}

Candidate fitTriangle(const std::vector<Vec> &loop, const std::vector<Vec> &hull, double area) {
    Candidate c;
    size_t h = hull.size();
    if (h < 3) return c;
    double bestArea = 0;
    std::vector<Vec> tri(3);
    for (size_t i = 0; i < h; i++) {
        for (size_t j = i + 1; j < h; j++) {
            for (size_t k = j + 1; k < h; k++) {
                double a = std::fabs(cross(hull[j] - hull[i], hull[k] - hull[i]));
                if (a > bestArea) { bestArea = a; tri = {hull[i], hull[j], hull[k]}; }
            }
        }
    }
    if (bestArea <= 0) return c;

    double longest = 0;
    for (int k = 0; k < 3; k++) longest = std::max(longest, dist(tri[k], tri[(k + 1) % 3]));

    // Re-fit each side (side k runs from corner k to corner k+1).
    Vec sideCentroid[3];
    double sideAngle[3];
    for (int k = 0; k < 3; k++) {
        Vec a = tri[k], b = tri[(k + 1) % 3];
        std::vector<Vec> near;
        for (Vec p : loop) {
            double d = distToSegment(p, a, b);
            if (d > distToSegment(p, b, tri[(k + 2) % 3]) || d > distToSegment(p, tri[(k + 2) % 3], a)) continue;
            double along = dot(p - a, b - a) / dot(b - a, b - a);
            if (along > 0.15 && along < 0.85) near.push_back(p);
        }
        if (near.size() >= 4) {
            sideAngle[k] = fitLineAngle(near, &sideCentroid[k]);
        } else {
            sideAngle[k] = std::atan2(b.y - a.y, b.x - a.x);
            sideCentroid[k] = (a + b) * 0.5;
        }
    }
    std::vector<Vec> refined = tri;
    for (int k = 0; k < 3; k++) {
        // Corner k is where side k-1 meets side k.
        int prev = (k + 2) % 3;
        Vec x;
        if (intersectLines(sideCentroid[prev], sideAngle[prev], sideCentroid[k], sideAngle[k], &x) &&
            dist(x, tri[k]) < 0.25 * longest) {
            refined[k] = x;
        }
    }
    tri = refined;

    double sides[3];
    longest = 0;
    for (int k = 0; k < 3; k++) {
        sides[k] = dist(tri[k], tri[(k + 1) % 3]);
        longest = std::max(longest, sides[k]);
    }
    for (int k = 0; k < 3; k++) {
        Vec a = tri[(k + 1) % 3] - tri[k], b = tri[(k + 2) % 3] - tri[k];
        double angle = std::atan2(std::fabs(cross(a, b)), dot(a, b));
        if (angle < radians(kTriangleMinAngleDeg)) return c;
    }
    // Shape size for a triangle: its shortest altitude.
    double size = std::fabs(cross(tri[1] - tri[0], tri[2] - tri[0])) / longest;
    double sumSq = 0, maxError = 0;
    for (Vec p : loop) {
        double d = distToOutline(p, tri);
        sumSq += d * d;
        maxError = std::max(maxError, d);
    }
    c.score = fitScore(std::sqrt(sumSq / loop.size()) / size, maxError / size, kPolygonRms, kPolygonMax);
    orderLikeStroke(tri, loop[0], area >= 0 ? 1 : -1);
    c.shape.kind = ShapeKind::Triangle;
    c.shape.vertices = tri;
    return c;
}

bool matchClosedShape(const std::vector<Vec> &p, double total, Shape *out) {
    std::vector<Vec> loop;
    if (!closeLoop(p, total, &loop)) return false;
    double turning = totalTurning(loop);
    if (turning < kClosedMinTurn || turning > kClosedMaxTurn) return false;
    double area = signedArea(loop);
    std::vector<Vec> hull = convexHull(loop);
    double hullArea = std::fabs(signedArea(hull));
    if (hullArea <= 0 || std::fabs(area) < kClosedMinConvexity * hullArea) return false;

    Candidate best = fitEllipse(loop, area);
    Candidate rectangle = fitRectangle(loop, hull, area);
    if (rectangle.score < best.score) best = rectangle;
    Candidate triangle = fitTriangle(loop, hull, area);
    if (triangle.score < best.score) best = triangle;
    if (best.score > 1.0) return false;
    *out = best.shape;
    return true;
}

// ===========================================================================
// Outline helpers
// ===========================================================================

// Appends points along a polyline: about `spacing` apart on the straights
// plus two points packed against each vertex (0.12 and 0.45 x spacing away).
// A cubic B-spline rounds a corner over roughly the gap between its control
// points, so packing them in keeps corners sharp and the two ends in place.
void densify(const std::vector<Vec> &vertices, double spacing, std::vector<Vec> *out) {
    if (vertices.empty()) return;
    out->push_back(vertices.front());
    for (size_t i = 1; i < vertices.size(); i++) {
        Vec a = vertices[i - 1], b = vertices[i];
        double len = dist(a, b);
        if (len <= 0) continue;
        std::vector<double> offsets = {0.12 * spacing, 0.45 * spacing, len - 0.45 * spacing, len - 0.12 * spacing};
        int steps = (int)std::floor(len / spacing);
        for (int s = 1; s < steps; s++) offsets.push_back(len * s / steps);
        std::sort(offsets.begin(), offsets.end());
        double last = 0;
        for (double o : offsets) {
            if (o <= last + 0.05 * spacing || o >= len - 0.05 * spacing) continue;
            out->push_back(a + (b - a) * (o / len));
            last = o;
        }
        out->push_back(b);
    }
}

} // namespace

// ===========================================================================
// Public API
// ===========================================================================

Hold trailingHold(const std::vector<Sample> &samples, double radius) {
    Hold hold;
    if (samples.empty()) return hold;
    const Sample &last = samples.back();
    hold.startTime = last.t;
    for (size_t i = samples.size(); i-- > 0;) {
        if (std::hypot(samples[i].x - last.x, samples[i].y - last.y) > radius) break;
        hold.startTime = samples[i].t;
    }
    hold.duration = last.t - hold.startTime;
    return hold;
}

std::vector<Vec> pointsBefore(const std::vector<Sample> &samples, double time) {
    std::vector<Vec> out;
    for (const Sample &s : samples) {
        if (s.t > time && !out.empty()) break;
        out.push_back(make(s.x, s.y));
    }
    return out;
}

Shape recognizeShape(const std::vector<Vec> &points, double unit, bool linesOnly) {
    Shape none;
    if (points.size() < 2 || unit <= 0) return none;
    double total = pathLength(points);
    if (total < kMinPathLengthPt * unit) return none;
    double minX = points[0].x, maxX = minX, minY = points[0].y, maxY = minY;
    for (Vec p : points) {
        minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y); maxY = std::max(maxY, p.y);
    }
    if (std::hypot(maxX - minX, maxY - minY) < kMinDiagonalPt * unit) return none;

    // Measure on the resampled path so sensor jitter does not inflate lengths.
    std::vector<Vec> p = resample(points, 128);
    total = pathLength(p);
    Shape shape;
    if (matchLine(p, total, unit, &shape)) return shape;
    if (linesOnly) return none;
    if (matchArrow(p, total, unit, &shape)) return shape;
    if (matchClosedShape(p, total, &shape)) return shape;
    return none;
}

std::vector<Vec> shapeOutline(const Shape &shape, double spacing) {
    std::vector<Vec> out;
    if (spacing <= 0) return out;
    const std::vector<Vec> &v = shape.vertices;
    switch (shape.kind) {
        case ShapeKind::None:
            break;
        case ShapeKind::Line:
            if (v.size() == 2) densify(v, spacing, &out);
            break;
        case ShapeKind::Arrow:
            // Tail to tip, out along one barb, back to the tip, out along the other.
            if (v.size() == 4) densify({v[0], v[1], v[2], v[1], v[3]}, spacing, &out);
            break;
        case ShapeKind::Rectangle:
        case ShapeKind::Triangle: {
            if (v.size() < 3) break;
            std::vector<Vec> closed = v;
            closed.push_back(v.front());
            densify(closed, spacing, &out);
            break;
        }
        case ShapeKind::Ellipse: {
            double a = shape.radiusA, b = shape.radiusB;
            if (a <= 0 || b <= 0) break;
            // Ramanujan's perimeter approximation, to choose the point count.
            double perimeter = kPi * (3 * (a + b) - std::sqrt((3 * a + b) * (a + 3 * b)));
            int count = std::max(48, (int)std::ceil(perimeter / spacing));
            Vec axisA = make(std::cos(shape.rotation), std::sin(shape.rotation));
            Vec axisB = make(-axisA.y, axisA.x);
            // One step past the full turn so the join is covered whether or
            // not the spline reaches its very first and last control points.
            for (int i = 0; i <= count + 1; i++) {
                double angle = shape.startAngle + shape.direction * 2 * kPi * i / count;
                out.push_back(shape.center + axisA * (a * std::cos(angle)) + axisB * (b * std::sin(angle)));
            }
            break;
        }
    }
    return out;
}

// Handwriting clean-up.
//
// Positions get a Taubin lambda/mu filter: each pass moves a point towards
// the midpoint of its neighbours (lambda) and then back out by slightly more
// (mu). Unlike plain averaging this does not shrink curves — it only removes
// wobble shorter than roughly ten sample spacings.
//
// What keeps it the writer's own hand:
//   - both endpoints are pinned, so strokes never get shorter;
//   - a point where the path turns by more than 45 degrees (measured over
//     2.5 pt arms) is a corner and is pinned;
//   - smoothing strength fades with the local turn and reaches zero at 60
//     degrees, so the tight curves that make up small letters are left alone;
//   - afterwards no point may sit more than 0.8 pt from where it was drawn.
// Width is nudged halfway towards its 5-sample average, which evens out
// pressure wobble but keeps the taper at each end.
SmoothResult smoothStroke(const std::vector<Sample> &samples, double unit) {
    SmoothResult result;
    result.samples = samples;
    int n = (int)samples.size();
    if (n < 5 || unit <= 0) return result;

    std::vector<Vec> original(n);
    for (int i = 0; i < n; i++) original[i] = make(samples[i].x, samples[i].y);
    double total = pathLength(original);
    if (total < kSmoothMinLengthPt * unit) return result;

    // Turn at each point, measured between arms of ~2.5 pt.
    double spacing = total / (n - 1);
    int arm = std::max(1, std::min(6, (int)std::lround(kSmoothArmPt * unit / spacing)));
    std::vector<double> turn(n, 0.0);
    for (int i = 1; i < n - 1; i++) {
        int k = std::min(arm, std::min(i, n - 1 - i));
        Vec a = original[i] - original[i - k], b = original[i + k] - original[i];
        if (length(a) > 0 && length(b) > 0) turn[i] = std::fabs(std::atan2(cross(a, b), dot(a, b)));
    }
    std::vector<double> weight(n, 0.0);
    double corner = radians(kSmoothCornerDeg), fade = radians(kSmoothFadeDeg);
    for (int i = 1; i < n - 1; i++) {
        bool localMax = true;
        for (int j = std::max(1, i - arm); j <= std::min(n - 2, i + arm); j++) {
            if (turn[j] > turn[i]) localMax = false;
        }
        if (turn[i] >= corner && localMax) continue;   // pinned corner
        weight[i] = std::max(0.0, 1.0 - turn[i] / fade);
    }

    std::vector<Vec> p = original, next(n);
    for (int iteration = 0; iteration < kSmoothIterations; iteration++) {
        for (double factor : {kSmoothLambda, kSmoothMu}) {
            next = p;
            for (int i = 1; i < n - 1; i++) {
                Vec mid = (p[i - 1] + p[i + 1]) * 0.5;
                next[i] = p[i] + (mid - p[i]) * (factor * weight[i]);
            }
            p.swap(next);
        }
    }

    double maxShift = kSmoothMaxShiftPt * unit;
    for (int i = 0; i < n; i++) {
        Vec shift = p[i] - original[i];
        double moved = length(shift);
        if (moved > maxShift) {
            p[i] = original[i] + shift * (maxShift / moved);
            moved = maxShift;
        }
        result.maxShift = std::max(result.maxShift, moved);
        result.samples[i].x = p[i].x;
        result.samples[i].y = p[i].y;
    }

    for (int i = 0; i < n; i++) {
        double sumW = 0, sumH = 0;
        int count = 0;
        for (int j = std::max(0, i - kSmoothWidthWindow); j <= std::min(n - 1, i + kSmoothWidthWindow); j++) {
            sumW += samples[j].w;
            sumH += samples[j].h;
            count++;
        }
        double w = samples[i].w + (sumW / count - samples[i].w) * kSmoothWidthBlend;
        double h = samples[i].h + (sumH / count - samples[i].h) * kSmoothWidthBlend;
        if (samples[i].w > 0) {
            result.maxWidthChange = std::max(result.maxWidthChange, std::fabs(w - samples[i].w) / samples[i].w);
        }
        result.samples[i].w = w;
        result.samples[i].h = h;
    }
    return result;
}

} // namespace StrokeRefiner
