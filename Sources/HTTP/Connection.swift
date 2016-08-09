import Foundation

public protocol StreamMiddleware {
    func parse(input data: Data, forConnection connection: Connection) -> Data
    func parse(output data: Data, forConnection connection: Connection) -> Data
}



public class Connection: NSObject, StreamDelegate {
    weak var server: Server?

    let inputStream: InputStream
    let outputStream: NSOutputStream
//    var context: [ConnectionMiddleware: Context] = [:]
    public private(set) var request: Request
    public private(set) var response: Response?

    public typealias Context = [String: Any]
    public var context = Context()

    init(server: Server, inputStream: InputStream, outputStream: NSOutputStream) {
        self.server = server
        self.inputStream = inputStream
        self.outputStream = outputStream
        self.request = Request()
        super.init()
        open()
    }

    func open() {
        inputStream.delegate = self
        outputStream.delegate = self

        inputStream.open()
        outputStream.open()

        inputStream.schedule(in: .main, forMode: .defaultRunLoopMode)
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch (aStream, eventCode) {
        case (_, Stream.Event.openCompleted): break

        case (inputStream, Stream.Event.hasBytesAvailable):
            var buffer = Data(count: 1024)!
            buffer.count = buffer.withUnsafeMutableBytes {
                inputStream.read($0, maxLength: buffer.count)
            }

            // Used [].reduce before, but resulted in corrupted memory; this as a workaround
            for middleware in server!.streamMiddleware {
                buffer = middleware.parse(input: buffer, forConnection: self)
            }

            try! request.append(data: buffer)

            if request.isHeaderComplete {
                response = server?.application(self, request)
                response!.headers["Connection"] = "Keep-Alive"

                inputStream.remove(from: .main, forMode: .defaultRunLoopMode)
                outputStream.schedule(in: .main, forMode: .defaultRunLoopMode)
            }

        case (outputStream, Stream.Event.hasSpaceAvailable):
            print(response?.status)
            guard let serialized = response?.serialized() else {
                abort()
            }

            let data = server!.streamMiddleware.reversed().reduce(serialized) { $1.parse(output: $0, forConnection: self) }

            let written = data.withUnsafeBytes {
                outputStream.write($0, maxLength: data.count)
            }

            response = nil
            request = Request()

            precondition(written == data.count)

            outputStream.remove(from: .main, forMode: .defaultRunLoopMode)
            inputStream.schedule(in: .main, forMode: .defaultRunLoopMode)

        case (_, Stream.Event.endEncountered), (_, Stream.Event.errorOccurred):
            print("end encountered, closing")
            close()

        default: break
        }
    }

    func close() {
        print("closing...")
        server?.forget(connection: self)
        inputStream.close()
        outputStream.close()
    }
    
    deinit {
        print("deinit, closing...")
        close()
    }
}
