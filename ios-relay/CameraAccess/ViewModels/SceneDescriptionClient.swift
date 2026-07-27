import Foundation

struct SceneDescriptionResponse: Decodable {
  let description: String
  let language: String
}

private struct SceneDescriptionRequest: Encodable {
  let imageB64s: [String]
  let question: String
  let language: String

  enum CodingKeys: String, CodingKey {
    case imageB64s = "image_b64s"
    case question
    case language
  }
}

private struct SceneDescriptionErrorResponse: Decodable {
  let error: String
}

enum SceneDescriptionClientError: LocalizedError {
  case invalidEndpoint
  case invalidResponse
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "The Mac relay address is invalid. Open Scene settings and check it."
    case .invalidResponse:
      return "The Mac relay returned an unreadable response."
    case .server(let message):
      return message
    }
  }
}

struct SceneDescriptionClient {
  static let endpointDefaultsKey = "sceneDescriptionEndpoint"
  static let languageDefaultsKey = "sceneDescriptionLanguage"
  static let defaultEndpoint = "http://Kangs-iMac.local:8787/describe"

  func answer(question: String, jpegFrames: [Data]) async throws -> SceneDescriptionResponse {
    let defaults = UserDefaults.standard
    let endpoint = defaults.string(forKey: Self.endpointDefaultsKey) ?? Self.defaultEndpoint
    let language = defaults.string(forKey: Self.languageDefaultsKey) ?? "en"

    guard let url = URL(string: endpoint), url.scheme != nil else {
      throw SceneDescriptionClientError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 75
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      SceneDescriptionRequest(
        imageB64s: jpegFrames.map { $0.base64EncodedString() },
        question: question,
        language: language
      )
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SceneDescriptionClientError.invalidResponse
    }
    guard 200..<300 ~= httpResponse.statusCode else {
      let message = (try? JSONDecoder().decode(SceneDescriptionErrorResponse.self, from: data).error)
        ?? "Scene description failed on the Mac relay."
      throw SceneDescriptionClientError.server(message)
    }
    return try JSONDecoder().decode(SceneDescriptionResponse.self, from: data)
  }
}
