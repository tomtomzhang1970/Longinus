//
//  ImageDownloadOperation.swift
//  Longinus
//
//  Created by Qitao Yang on 2020/5/13.
//
//  Copyright (c) 2020 KittenYang <kittenyang@icloud.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
    

import UIKit

public protocol ImageDownloadOperateable: AnyObject {
    var url: URL { get }
    var dataTaskId: Int { get }
    var downloadInfos: [ImageDownloadInfo] { get }
    var imageCoder: ImageCodeable? { get set }
    var completion: (() -> Void)? { get set }
    
    init(request: URLRequest, session: URLSession, options: ImageOptions)
    func add(info: ImageDownloadInfo)
    func start()
    func cancel()
}


class ImageDownloadOperation: NSObject, ImageDownloadOperateable {
    
    var url: URL { return request.url! }
    
    var dataTaskId: Int {
        stateLock.lock()
        let tid = dataTask?.taskIdentifier ?? 0
        stateLock.unlock()
        return tid
    }
    
    weak var imageCoder: ImageCodeable?
    private var imageProgressiveCoder: ImageProgressiveCodeable?
    
    var completion: (() -> Void)?
    
    private let request: URLRequest
    private let session: URLSession
    private var infos: [ImageDownloadInfo]
    private var dataTask: URLSessionTask?
    private let taskLock: DispatchSemaphore
    private let stateLock: DispatchSemaphore
    private var imageData: Data?
    private var expectedSize: Int
    
    private var cancelled: Bool
    private var finished: Bool
    private var downloadFinished: Bool
    private var options: ImageOptions
    
    private lazy var progressiveCoderQueue: DispatchQueuePool = {
        return DispatchQueuePool.utility
    }()
    
    var downloadInfos: [ImageDownloadInfo] {
        taskLock.lock()
        let currentTasks = infos
        taskLock.unlock()
        return currentTasks
    }
    
    required init(request: URLRequest, session: URLSession, options: ImageOptions) {
        self.request = request
        self.session = session
        self.options = options
        infos = []
        taskLock = DispatchSemaphore(value: 1)
        stateLock = DispatchSemaphore(value: 1)
        expectedSize = 0
        cancelled = false
        finished = false
        downloadFinished = false
    }
    
    func add(info: ImageDownloadInfo) {
        taskLock.lock()
        infos.append(info)
        taskLock.unlock()
    }
    
    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if cancelled || finished {
            if let url = request.url {
                if !url.isFileURL && options.contains(.showNetworkActivity) {
                    NetworkIndicatorManager.decrementNetworkActivityCount()
                }
            }
            return
        } // Completion call back will not be called when task is cancelled
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
        if let url = request.url {
            if !url.isFileURL && options.contains(.showNetworkActivity) {
                NetworkIndicatorManager.incrementNetworkActivityCount()
            }
        }
    }
    
    func cancel() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if finished {
            if let url = request.url {
                if !url.isFileURL && options.contains(.showNetworkActivity) {
                    NetworkIndicatorManager.decrementNetworkActivityCount()
                }
            }
            return
        }
        cancelled = true
        dataTask?.cancel()
        done()
    }
    
    private func done() {
        finished = true
        dataTask = nil
        if let url = request.url {
            if !url.isFileURL && options.contains(.showNetworkActivity) {
                NetworkIndicatorManager.decrementNetworkActivityCount()
            }
        }
        completion?()
        completion = nil
    }
}

extension ImageDownloadOperation: URLSessionTaskDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        downloadFinished = true
        if error != nil {
            complete(withData: nil, error: error)
        } else {
            if let data = imageData {
                complete(withData: data, error: nil)
            } else {
                let noDataError = NSError(domain: LonginusImageErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey : "No image data"])
                complete(withData: nil, error: noDataError)
            }
        }
        stateLock.unlock()
        stateLock.lock()
        done()
        stateLock.unlock()
    }
    
    private func complete(withData data: Data?, error: Error?) {
        taskLock.lock()
        let currentInfos = infos
        taskLock.unlock()
        for info in currentInfos where !info.isCancelled {
            info.completion(data, error)
        }
    }
    
}

extension ImageDownloadOperation: URLSessionDataDelegate {
    
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expectedSize = max(0, Int(response.expectedContentLength))
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        if statusCode >= 400 || statusCode == 304 {
            completionHandler(.cancel)
        } else {
            progress(with: nil, expectedSize: expectedSize, image: nil)
            completionHandler(.allow)
        }
    }
    
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        if imageData == nil { imageData = Data(capacity: expectedSize) }
        imageData?.append(data)
        guard let currentImageData = imageData else { return }
        
        if let coder = imageCoder,
            imageProgressiveCoder == nil {
            if let coderManager = coder as? ImageCoderManager {
                let coders = coderManager.coders
                for coder in coders {
                    if let progressiveCoder = coder as? ImageProgressiveCodeable,
                        progressiveCoder.canIncrementallyDecode(currentImageData) {
                        imageProgressiveCoder = progressiveCoder.copy() as? ImageProgressiveCodeable
                        break
                    }
                }
            } else if let progressiveCoder = coder as? ImageProgressiveCodeable {
                imageProgressiveCoder = progressiveCoder.copy() as? ImageProgressiveCodeable
            }
        }
        if let progressiveCoder = imageProgressiveCoder {
            let size = expectedSize
            let finished = currentImageData.count >= size
            progressiveCoderQueue.async { [weak self] in
                guard let self = self, !self.cancelled, !self.finished else { return }
                let image = progressiveCoder.incrementallyDecodedImage(with: currentImageData, finished: finished)
                self.progress(with: currentImageData, expectedSize: size, image: image)
            }
        } else {
            progress(with: currentImageData, expectedSize: expectedSize, image: nil)
        }
    }
    
    private func progress(with data: Data?,
                          expectedSize: Int,
                          image: UIImage?) {
        taskLock.lock()
        let currentInfos = infos
        taskLock.unlock()
        stateLock.lock()
        defer { stateLock.unlock() }
        if downloadFinished { return }
        for info in currentInfos where !info.isCancelled {
            info.progress?(data, expectedSize, image)
        }
    }
    
}
