//
//  FetchService.swift
//  Loader
//
//  Created by samara on 14.03.2025.
//

import Foundation

// MARK: - Class
public class NBFetchService {
	
	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case noData
		case parsingError(Any)
		
		public var errorDescription: String? {
			switch self {
			case .invalidURL:
				return "The URL is invalid."
			case .networkError(let error):
				return "Network error: \(error.localizedDescription)"
			case .noData:
				return "No data received."
			case .parsingError(let error):
				return "Failed to parse data: \(error)"
			}
		}
	}
	
	public init() {}
}

// MARK: - Class extension: fetch
extension NBFetchService {
	public func fetch<T: Decodable>(
		from urlString: String,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(NBFetchServiceError.invalidURL))
			return
		}
		
		fetch(from: url, completion: completion)
	}
	
	public func fetch<T: Decodable>(
        from url: URL,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(NBFetchServiceError.networkError(error)))
                return
            }
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                completion(.failure(NBFetchServiceError.networkError(
                    NSError(domain: "HTTP", code: response.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"])
                )))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(NBFetchServiceError.noData))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(T.self, from: data)))
            } catch {
                // Always resume callers' continuations, including dataCorrupted errors
                // without an underlying NSError (the old code could wait forever).
                completion(.failure(NBFetchServiceError.parsingError(error)))
            }
        }.resume()
    }

}
