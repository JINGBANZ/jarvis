import Foundation

/// The reply did not reach its terminal event. `errorBody` is the provider's error event in the
/// shape its failure table reads; nil when the stream simply closed.
struct StreamFailure: Error {
    let errorBody: Data?
}
