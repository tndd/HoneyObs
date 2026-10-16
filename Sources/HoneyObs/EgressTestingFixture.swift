#if EGRESS_TESTING
import Foundation
import Virtualization
import Network
import Darwin

// OS所有・二台VMの故障試験専用。製品バイナリにはコンパイルしない。
// 偽の資格情報と127.0.0.1のedge以外へ接続する経路を持たない。
final class EgressTestingFixture {
    private let listener: NWListener, originPort: () -> UInt16
    private let permit = ForwardingPermit(confirmedAt:safetyTime())
    private var timer: Timer?, peers: [NWConnection] = [], streams: [UUID:EgressStream] = [:]
    private var port: UInt16 = 0
    private(set) var apiCalls = 0, edgeDials = 0, invalidHello = false
    var status: [String:Any] { ["apiCalls":apiCalls,"fakeEdgeDials":edgeDials,"invalidHello":invalidHello] }
    init(originPort: @escaping () -> UInt16) throws {
        self.originPort=originPort
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener=try NWListener(using:parameters)
        listener.stateUpdateHandler={ [weak self] state in if case .ready=state{self?.port=self?.listener.port?.rawValue ?? 0} }
        listener.newConnectionHandler={ [weak self] connection in
            guard let self else {connection.cancel();return};self.peers.append(connection);self.edgeDials += 1
            connection.start(queue:.main);self.readHello(connection,bytes:Data())
        }
        listener.start(queue:.main)
        timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self]_ in guard let self else{return};_=self.permit.renew(confirmedAt:safetyTime())}
    }
    private func readHello(_ connection:NWConnection,bytes:Data){
        connection.receive(minimumIncompleteLength:1,maximumLength:16384){[weak self]data,_,done,error in
            guard let self else{connection.cancel();return};let bytes=bytes+(data ?? Data())
            if bytes.count>=5 {
                let size=5+(Int(bytes[3])<<8|Int(bytes[4]))
                if bytes.count>=size {
                    if !EgressPolicy.allowsEdgeHello(bytes.prefix(size)){self.invalidHello=true}
                    connection.send(content:Data([21,3,3,0,2,2,40]),completion:.contentProcessed{_ in connection.cancel()});return
                }
            }
            if done || error != nil || bytes.count>16384{connection.cancel()}else{self.readHello(connection,bytes:bytes)}
        }
    }
    func handle(_ port:UInt32,connection:VZVirtioSocketConnection,finished:@escaping()->Void){
        if port == 9001 {
            apiCalls += 1
            DispatchQueue.global().async {
                let fd=connection.fileDescriptor;_=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) & ~O_NONBLOCK)
                var timeout=timeval(tv_sec:2,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                var noSig:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSig,socklen_t(MemoryLayout<Int32>.size))
                var header=Data(),byte:UInt8=0
                while header.count<4096 && !header.suffix(4).elementsEqual([13,10,13,10]){if Darwin.read(fd,&byte,1) != 1{break};header.append(byte)}
                if EgressPolicy.allowsProvision(header){
                    let body=Data("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"00000000-0000-0000-0000-000000000001\",\"hostname\":\"local-fixture.trycloudflare.com\",\"account_tag\":\"local-test\",\"secret\":\"bG9jYWw=\"}}".utf8)
                    let response=Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)+body
                    response.withUnsafeBytes{_ = Darwin.write(fd,$0.baseAddress,$0.count)}
                }
                connection.close();finished()
            };return
        }
        let target:UInt16=port == 9000 ? originPort() : self.port
        guard target>0 else{connection.close();finished();return}
        let id=UUID(),stream=EgressStream(guest:connection,host:"127.0.0.1",port:target,mode:port == 9000 ? .origin:.edge,permit:permit){[weak self]in self?.streams.removeValue(forKey:id);finished()}
        streams[id]=stream;stream.start()
    }
    deinit{timer?.invalidate();permit.revoke();listener.cancel();peers.forEach{$0.cancel()};streams.values.forEach{$0.cancel()}}
}
#endif
