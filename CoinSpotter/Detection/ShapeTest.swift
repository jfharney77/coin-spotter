import Foundation

/// Every number that decides what the on-phone filter lets through.
/// These are starting values chosen on paper; tune them against the live
/// preview (candidate boxes are drawn on it) once the app runs on a device.
enum Tuning {
  /// Frames per second requested from the glasses (valid: 2, 7, 15, 24, 30).
  static let streamFrameRate: UInt = 7
  /// Minimum seconds between frames handed to the on-phone filter.
  static let analysisInterval: TimeInterval = 0.5
  /// Minimum seconds between Claude confirmation requests.
  static let verifyInterval: TimeInterval = 4
  /// Hard ceiling on Claude requests in any rolling hour.
  static let maxVerificationsPerHour = 300
  /// After an alert, stay quiet this long so one coin is announced once.
  static let alertCooldown: TimeInterval = 20
  /// Most candidates sent to Claude in a single request.
  static let maxCandidatesPerRequest = 3

  /// Smallest coin outline worth looking at, in pixels of the 720-wide frame.
  static let minWidthPixels = 8.0
  static let minHeightPixels = 4.0
  /// Largest outline, as a fraction of frame width.
  static let maxWidthFraction = 0.15
  /// A coin on the ground seen from head height is an ellipse wider than tall.
  static let aspectRange = 0.8...4.0
  /// Outline area divided by the area of the ellipse inscribed in its bounding box.
  static let ellipseFillRange = 0.78...1.12
  /// Outline length divided by that ellipse's circumference (ragged edges score high).
  static let perimeterRatioRange = 0.88...1.25
  /// Minimum brightness difference (0-255) between the object and the ground around it.
  static let minContrast = 18.0
}

/// Geometry of one closed outline, in pixels with the origin at the top left.
struct OutlineShape {
  let minX: Double
  let minY: Double
  let width: Double
  let height: Double
  let area: Double
  let perimeter: Double

  init?(points: [(x: Double, y: Double)]) {
    guard points.count >= 6 else { return nil }
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    var twiceArea = 0.0
    var perimeter = 0.0
    for index in points.indices {
      let a = points[index]
      let b = points[(index + 1) % points.count]
      minX = min(minX, a.x); maxX = max(maxX, a.x)
      minY = min(minY, a.y); maxY = max(maxY, a.y)
      twiceArea += a.x * b.y - b.x * a.y
      perimeter += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
    }
    self.minX = minX
    self.minY = minY
    self.width = maxX - minX
    self.height = maxY - minY
    self.area = abs(twiceArea) / 2
    self.perimeter = perimeter
  }

  /// True when the outline has the size and shape of a coin lying on the ground.
  func looksLikeCoin(frameWidth: Double) -> Bool {
    guard width >= Tuning.minWidthPixels, height >= Tuning.minHeightPixels,
      width <= frameWidth * Tuning.maxWidthFraction
    else { return false }
    guard Tuning.aspectRange.contains(width / height) else { return false }

    let a = width / 2, b = height / 2
    let ellipseArea = Double.pi * a * b
    guard Tuning.ellipseFillRange.contains(area / ellipseArea) else { return false }

    // Ramanujan's approximation for the circumference of an ellipse.
    let h = ((a - b) * (a - b)) / ((a + b) * (a + b))
    let ellipsePerimeter = Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
    return Tuning.perimeterRatioRange.contains(perimeter / ellipsePerimeter)
  }
}

/// A possible coin found by the on-phone filter.
struct Candidate {
  /// Bounding box as fractions of the frame, origin at the top left.
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  /// Brightness difference from the surrounding ground; higher sorts first.
  let contrast: Double

  var centerX: Double { x + width / 2 }
  var centerY: Double { y + height / 2 }

  func overlaps(_ other: Candidate) -> Bool {
    let left = max(x, other.x), right = min(x + width, other.x + other.width)
    let top = max(y, other.y), bottom = min(y + height, other.y + other.height)
    guard right > left, bottom > top else { return false }
    let intersection = (right - left) * (bottom - top)
    let union = width * height + other.width * other.height - intersection
    return intersection / union > 0.4
  }

  /// Spoken position, e.g. "ahead on your left, a few steps away".
  var spokenPosition: String {
    let side: String
    switch centerX {
    case ..<0.38: side = "ahead on your left"
    case 0.62...: side = "ahead on your right"
    default: side = "straight ahead"
    }
    let distance = centerY > 0.66 ? "near your feet" : "a few steps away"
    return "\(side), \(distance)"
  }
}
