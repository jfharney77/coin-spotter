import Foundation

enum ClaudeModel: String, CaseIterable, Identifiable {
  case opus = "claude-opus-5-5"
  case sonnet = "claude-sonnet-5-5"
  case haiku = "claude-haiku-5-5"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .opus: return "Opus 5.5 (most accurate)"
    case .sonnet: return "Sonnet 5.5"
    case .haiku: return "Haiku 5.5 (cheapest)"
    }
  }

  /// Haiku has no server-side refusal fallback, so the parameter is only sent for the others.
  var supportsFallbacks: Bool { self != .haiku }
}

enum ClaudeError: LocalizedError {
  case badKey
  case rateLimited
  case http(Int, String)
  case refused
  case unreadable

  var errorDescription: String? {
    switch self {
    case .badKey: return "Claude rejected the API key. Check it in Settings."
    case .rateLimited: return "Claude rate limit reached. Confirmation will resume shortly."
    case .http(let status, let message): return "Claude returned an error (\(status)): \(message)"
    case .refused: return "Claude declined to look at the image."
    case .unreadable: return "Claude's reply could not be read."
    }
  }
}

/// Asks Claude which of the cropped images really show a coin.
struct ClaudeVerifier {
  let apiKey: String
  let model: ClaudeModel
  var session: URLSession = .shared

  /// - Parameter crops: JPEG data, one image per candidate.
  /// - Returns: zero-based indices of the crops Claude says contain a coin.
  func coinIndices(in crops: [Data]) async throws -> Set<Int> {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
    if model.supportsFallbacks {
      request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, crops: crops))

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      if status == 401 { throw ClaudeError.badKey }
      if status == 429 { throw ClaudeError.rateLimited }
      throw ClaudeError.http(status, Self.errorMessage(from: data))
    }
    return try Self.parse(data, cropCount: crops.count)
  }

  static func body(model: ClaudeModel, crops: [Data]) -> [String: Any] {
    var content: [[String: Any]] = []
    for (index, crop) in crops.enumerated() {
      content.append(["type": "text", "text": "Image \(index + 1):"])
      content.append([
        "type": "image",
        "source": [
          "type": "base64",
          "media_type": "image/jpeg",
          "data": crop.base64EncodedString(),
        ],
      ])
    }
    content.append(["type": "text", "text": prompt])

    var body: [String: Any] = [
      "model": model.rawValue,
      "max_tokens": 2048,
      "messages": [["role": "user", "content": content]],
      "output_config": [
        "effort": "low",
        "format": [
          "type": "json_schema",
          "schema": [
            "type": "object",
            "properties": [
              "coin_images": ["type": "array", "items": ["type": "integer"]]
            ],
            "required": ["coin_images"],
            "additionalProperties": false,
          ],
        ],
      ],
    ]
    if model.supportsFallbacks {
      body["fallbacks"] = "default"
    }
    return body
  }

  static let prompt = """
    These images are crops from a camera worn on someone's head while they walk. \
    Each crop is centred on a small round object on the ground that an automatic \
    filter flagged as a possible coin. The wearer wants to pick up dropped money.

    For each image, decide whether the object at the centre is a real coin lying \
    on the ground. Bottle caps, washers, buttons, manhole covers, drain grates, \
    stains, chewing gum, leaves, pebbles and reflections are not coins. Count an \
    image only when you are reasonably confident, because a false alert makes the \
    wearer stop and bend down for nothing.

    In coin_images, list the numbers of the images that show a coin. Use an empty \
    list when none do.
    """

  static func parse(_ data: Data, cropCount: Int) throws -> Set<Int> {
    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ClaudeError.unreadable
    }
    if reply["stop_reason"] as? String == "refusal" { throw ClaudeError.refused }
    guard let blocks = reply["content"] as? [[String: Any]],
      let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
      let answer = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let numbers = answer["coin_images"] as? [Int]
    else { throw ClaudeError.unreadable }
    return Set(numbers.map { $0 - 1 }.filter { (0..<cropCount).contains($0) })
  }

  private static func errorMessage(from data: Data) -> String {
    let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let error = reply?["error"] as? [String: Any]
    return error?["message"] as? String ?? "no details"
  }
}
