import Foundation
#if !COCOAPODS
import ApolloCore
#endif

public class RequestChain: Cancellable {
  
  public enum ChainError: Error {
    case invalidIndex(chain: RequestChain, index: Int)
    case noInterceptors
  }
  
  private let interceptors: [ApolloInterceptor]
  private var currentIndex: Int
  public private(set) var callbackQueue: DispatchQueue
  public private(set) var isCancelled = Atomic<Bool>(false)
  
  /// Helper var for readability in guard statements
  public var isNotCancelled: Bool {
    !self.isCancelled.value
  }
  
  /// Something which allows additional error handling to occur when some kind of error has happened.
  public var additionalErrorHandler: ApolloErrorInterceptor?
  
  /// Creates a chain with the given interceptor array.
  ///
  /// - Parameters:
  ///   - interceptors: The array of interceptors to use.
  ///   - callbackQueue: The `DispatchQueue` to call back on when an error or result occurs. Defauls to `.main`.
  public init(interceptors: [ApolloInterceptor],
              callbackQueue: DispatchQueue = .main) {
    self.interceptors = interceptors
    self.callbackQueue = callbackQueue
    self.currentIndex = 0
  }
  
  /// Kicks off the request from the beginning of the interceptor array.
  ///
  /// - Parameters:
  ///   - request: The request to send.
  ///   - completion: The completion closure to call when the request has completed.
  public func kickoff<ParsedValue: Parseable, Operation: GraphQLOperation>(request: HTTPRequest<Operation>, completion: @escaping (Result<ParsedValue, Error>) -> Void) {
    assert(self.currentIndex == 0, "The interceptor index should be zero when calling this method")
    
    let response: HTTPResponse<ParsedValue> = HTTPResponse(response: nil,
                                                           rawData: nil,
                                                           parsedResponse: nil)
    guard let firstInterceptor = self.interceptors.first else {
      handleErrorAsync(ChainError.noInterceptors,
                       request: request,
                       response: response,
                       completion: completion)
      return
    }
    
    firstInterceptor.interceptAsync(chain: self,
                                    request: request,
                                    response: response,
                                    completion: completion)
  }

  /// Proceeds to the next interceptor in the array.
  ///
  /// - Parameters:
  ///   - request: The in-progress request object
  ///   - response: The in-progress response object
  ///   - completion: The completion closure to call when data has been processed and should be returned to the UI.
  public func proceedAsync<ParsedValue: Parseable, Operation: GraphQLOperation>(request: HTTPRequest<Operation>,
                           response: HTTPResponse<ParsedValue>,
                           completion: @escaping (Result<ParsedValue, Error>) -> Void) {
    guard self.isNotCancelled else {
      // Do not proceed, this chain has been cancelled.
      return
    }
    
    let nextIndex = self.currentIndex + 1
    guard self.interceptors.indices.contains(nextIndex) else {
      self.handleErrorAsync(ChainError.invalidIndex(chain: self, index: nextIndex),
                            request: request,
                            response: response,
                            completion: completion)
      return
    }
    
    self.currentIndex = nextIndex
    let interceptor = self.interceptors[self.currentIndex]
    
    interceptor.interceptAsync(chain: self,
                               request: request,
                               response: response,
                               completion: completion)
  }
  
  /// Cancels the entire chain of interceptors.
  public func cancel() {
    self.isCancelled.value = true
    
    // If an interceptor adheres to `Cancellable`, it should have its in-flight work cancelled as well.
    for interceptor in self.interceptors {
      if let cancellableInterceptor = interceptor as? Cancellable {
        cancellableInterceptor.cancel()
      }
    }
  }
  
  /// Restarts the request starting from the first inteceptor.
  ///
  /// - Parameters:
  ///   - request: The request to retry
  ///   - completion: The completion closure to call when the request has completed.
  public func retry<ParsedValue: Parseable, Operation: GraphQLOperation>(
    request: HTTPRequest<Operation>,
    completion: @escaping (Result<ParsedValue, Error>) -> Void) {
    
    guard self.isNotCancelled else {
      // Don't retry something that's been cancelled.
      return
    }
    
    request.retryCount += 1
    self.currentIndex = 0
    self.kickoff(request: request, completion: completion)
  }
  
  /// Handles the error by returning it, or by applying an additional error interceptor if one has been provided.
  ///
  /// - Parameters:
  ///   - error: The error to handle
  ///   - request: The request, as far as it has been constructed.
  ///   - response: The response, as far as it has been constructed.
  ///   - completion: The completion closure to call when work is complete.
  public func handleErrorAsync<ParsedValue: Parseable, Operation: GraphQLOperation>(
    _ error: Error,
    request: HTTPRequest<Operation>,
    response: HTTPResponse<ParsedValue>,
    completion: @escaping (Result<ParsedValue, Error>) -> Void) {
    guard self.isNotCancelled else {
      return
    }

    guard let additionalHandler = self.additionalErrorHandler else {
      self.callbackQueue.async {
        completion(.failure(error))
      }
      return
    }
    
    
    additionalHandler.handleErrorAsync(error: error,
                                       chain: self,
                                       request: request,
                                       response: response,
                                       completion: completion)
  }
  
  public func returnValueAsync<ParsedValue: Parseable>(
    value: ParsedValue,
    completion: @escaping (Result<ParsedValue, Error>) -> Void) {
   
    guard self.isNotCancelled else {
      return
    }
    
    self.callbackQueue.async {
      completion(.success(value))
    }
  }
}