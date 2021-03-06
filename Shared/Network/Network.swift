//
//  Downloader.swift
//  Kiwix
//
//  Created by Chris Li on 1/24/17.
//  Copyright © 2017 Chris Li. All rights reserved.
//

class Network: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    static let shared = Network()
    let bookSizeThreshold: Int64 = 100000000
    private override init() {
        super.init()
        _ = wifiSession
        _ = cellularSession
    }
    var progresses = [String: Int64]()
    let managedObjectContext = AppDelegate.persistentContainer.viewContext
    var timer: Timer?
    
    lazy var wifiSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "org.kiwix.wifi")
        configuration.allowsCellularAccess = false
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    lazy var cellularSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "org.kiwix.cellular")
        configuration.allowsCellularAccess = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    var backgroundEventsCompleteProcessing = [String: () -> Void]()
    
    // MARK: - actions
    
    func start(bookID: String, useWifiAndCellular: Bool?) {
        managedObjectContext.perform {
            guard let book = Book.fetch(bookID, context: self.managedObjectContext),
                let url = book.url else {return}
            let session: URLSession = {
                if let useWifiAndCellular = useWifiAndCellular {
                    return useWifiAndCellular ? self.cellularSession : self.wifiSession
                } else {
                    return book.fileSize > self.bookSizeThreshold ? self.wifiSession : self.cellularSession
                }
            }()
            let task = session.downloadTask(with: url)
            task.taskDescription = book.id
            task.resume()
            
            book.state = .downloading
            let downloadTask = DownloadTask.fetch(bookID: bookID, context: self.managedObjectContext)
            downloadTask?.state = .queued
            
            if self.managedObjectContext.hasChanges { try? self.managedObjectContext.save() }
            
            self.progresses[bookID] = 0
            if self.progresses.count == 1 { self.startTimer() }
            
            NetworkActivityController.shared.taskDidStart(identifier: bookID)
        }
    }
    
    func pause(bookID: String) {
        cancelTask(in: wifiSession, taskDescription: bookID, producingResumingData: true)
        cancelTask(in: cellularSession, taskDescription: bookID, producingResumingData: true)
        
        self.managedObjectContext.perform({
            guard let book = Book.fetch(bookID, context: self.managedObjectContext) else {return}
            if book.state != .downloading {book.state = .downloading}
            book.downloadTask?.state = .paused
            if self.managedObjectContext.hasChanges { try? self.managedObjectContext.save() }
        })
    }
    
    func cancel(bookID: String) {
        cancelTask(in: wifiSession, taskDescription: bookID, producingResumingData: false)
        cancelTask(in: cellularSession, taskDescription: bookID, producingResumingData: false)
        
        self.managedObjectContext.perform({
            guard let book = Book.fetch(bookID, context: self.managedObjectContext) else {return}
            book.meta4URL != nil ? book.state = .cloud : self.managedObjectContext.delete(book)
            if let downloadTask = book.downloadTask {self.managedObjectContext.delete(downloadTask)}
            if self.managedObjectContext.hasChanges { try? self.managedObjectContext.save() }
        })
    }
    
    func resume(bookID: String) {
        guard let data = Preference.resumeData[bookID] else {return}
        let bookSizeIsBig: Bool = {
            guard let size = Book.fetch(bookID, context: self.managedObjectContext)?.fileSize else {return true}
            return size > bookSizeThreshold
        }()
        let task = (bookSizeIsBig ? wifiSession : cellularSession).downloadTask(withResumeData: data)
        task.taskDescription = bookID
        task.resume()
        
        let downloadTask = DownloadTask.fetch(bookID: bookID, context: managedObjectContext)
        downloadTask?.state = .queued
        
        if self.managedObjectContext.hasChanges { try? self.managedObjectContext.save() }
        
        progresses[bookID] = 0
        if progresses.count == 1 { startTimer() }
        
        NetworkActivityController.shared.taskDidStart(identifier: bookID)
    }
    
    private func cancelTask(in session: URLSession, taskDescription: String, producingResumingData: Bool) {
        session.getTasksWithCompletionHandler { (_, _, downloadTasks) in
            guard let task = downloadTasks.filter({$0.taskDescription == taskDescription}).first else {return}
            if producingResumingData {
                task.cancel(byProducingResumeData: {data in Preference.resumeData[taskDescription] = data })
            } else {
                task.cancel()
            }
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { (timer) in
            self.managedObjectContext.perform({ 
                for (bookID, bytesWritten) in self.progresses {
                    guard let book = Book.fetch(bookID, context: self.managedObjectContext) else {continue}
                    book.downloadTask?.totalBytesWritten = bytesWritten
                }
            })
        })
    }
    
    // MARK: - URLSessionTaskDelegate
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {print("Download error: \(error.localizedDescription)")}
        guard let bookID = task.taskDescription else {return}
        progresses[bookID] = nil
        if progresses.count == 0 { timer?.invalidate() }
        
        if let error = error as NSError?, error.code == URLError.cancelled.rawValue {
            self.managedObjectContext.perform({
                if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    Preference.resumeData[bookID] = data
                }
            })
        }
        
        if let identifier = session.configuration.identifier,
            let handler = backgroundEventsCompleteProcessing[identifier] {
            handler()
        }
        
        NetworkActivityController.shared.taskDidFinish(identifier: bookID)
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        managedObjectContext.perform { 
            guard let bookID = downloadTask.taskDescription,
                let book = Book.fetch(bookID, context: self.managedObjectContext) else {return}
            if book.state != .downloading {book.state = .downloading}
            if book.downloadTask?.state != .downloading {book.downloadTask?.state = .downloading}
            self.progresses[bookID] = totalBytesWritten
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let bookID = downloadTask.taskDescription else {return}
        
        if let docDirURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileName = {
                return downloadTask.response?.suggestedFilename
                    ?? downloadTask.originalRequest?.url?.lastPathComponent
                    ?? bookID
            }()
            let destination = docDirURL.appendingPathComponent(fileName)
            try? FileManager.default.moveItem(at: location, to: destination)
        }
        
        managedObjectContext.perform {
            guard let book = Book.fetch(bookID, context: self.managedObjectContext),
                let downloadTask = DownloadTask.fetch(bookID: bookID, context: self.managedObjectContext) else {return}
            book.state = .local
            self.managedObjectContext.delete(downloadTask)
            if self.managedObjectContext.hasChanges { try? self.managedObjectContext.save() }
            
            if Preference.Notifications.bookDownloadFinish {
                AppNotification.shared.downloadFinished(bookID: book.id,
                                                        bookTitle: book.title ?? "Book",
                                                        fileSizeDescription: book.fileSizeDescription)
            }
        }
    }
}
