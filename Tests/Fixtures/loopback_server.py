"""HTTP fixture startup must not depend on the runner's DNS resolver."""
from http.server import ThreadingHTTPServer
from socketserver import TCPServer


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls socket.getfqdn before listen(). Both
        # fixtures bind a numeric loopback address and do not need reverse DNS.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address
