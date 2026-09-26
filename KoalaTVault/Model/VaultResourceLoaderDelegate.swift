//
//  VaultResourceLoaderDelegate.swift
//  KoalaTVault
//

import AVFoundation
import UniformTypeIdentifiers

/// Intercepts AVPlayer's byte-range requests and serves decrypted chunks on demand,
/// so large encrypted videos can start playing without decrypting the whole file first.
final class VaultResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let encryptedURL: URL
    private let totalSize: Int
    private let chunkSize: Int
    private let contentType: UTType

    init?(encryptedURL: URL, fileExtension: String) {
        guard let info = try? CryptoService.shared.streamInfo(for: encryptedURL) else { return nil }
        self.encryptedURL = encryptedURL
        self.totalSize = info.totalSize
        self.chunkSize = info.chunkSize
        self.contentType = UTType(filenameExtension: fileExtension) ?? .mpeg4Movie
        super.init()
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.fulfill(loadingRequest)
        }
        return true
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                         didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // no-op: fulfill() checks loadingRequest.isCancelled itself each iteration
    }

    nonisolated private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = contentType.identifier
            infoRequest.contentLength = Int64(totalSize)
            infoRequest.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let requestedOffset = Int(dataRequest.requestedOffset)
        let endOffset = dataRequest.requestsAllDataToEndOfResource
            ? totalSize
            : min(requestedOffset + dataRequest.requestedLength, totalSize)

        guard requestedOffset < endOffset else {
            loadingRequest.finishLoading()
            return
        }

        let firstChunk = requestedOffset / chunkSize
        let lastChunk = (endOffset - 1) / chunkSize

        do {
            for chunkIndex in firstChunk...lastChunk {
                try autoreleasepool {
                    guard !loadingRequest.isCancelled else { return }
                    let chunkData = try CryptoService.shared.decryptChunk(
                        at: chunkIndex, from: encryptedURL, chunkSize: chunkSize, totalSize: totalSize
                    )
                    let chunkStart = chunkIndex * chunkSize
                    let sliceStart = max(requestedOffset, chunkStart) - chunkStart
                    let sliceEnd = min(endOffset, chunkStart + chunkData.count) - chunkStart
                    guard sliceStart < sliceEnd else { return }
                    dataRequest.respond(with: chunkData.subdata(in: sliceStart..<sliceEnd))
                }
            }
            if !loadingRequest.isCancelled { loadingRequest.finishLoading() }
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }
}
