package gnmi

import (
	"crypto/tls"
	"io"
	"net"
	"sync"
	"time"
)

// chanListener is a net.Listener backed by a channel of accepted conns, so a
// grpc.Server can be fed connections selected by the dispatcher.
type chanListener struct {
	ch   chan net.Conn
	once sync.Once
	addr net.Addr
}

func (l *chanListener) Accept() (net.Conn, error) {
	c, ok := <-l.ch
	if !ok {
		return nil, io.EOF
	}
	return c, nil
}

func (l *chanListener) Close() error {
	l.once.Do(func() { close(l.ch) })
	return nil
}

func (l *chanListener) Addr() net.Addr { return l.addr }

// replayConn wraps a conn whose first byte has already been read, replaying
// it to the reader.
type replayConn struct {
	net.Conn
	first byte
	done  bool
}

func (c *replayConn) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	if !c.done {
		c.done = true
		b[0] = c.first
		n, err := c.Conn.Read(b[1:])
		if n == 0 && err != nil {
			return 0, err
		}
		return n + 1, nil
	}
	return c.Conn.Read(b)
}

// newSwitchingListener sniffs the first byte of each connection: 0x16 (TLS
// ClientHello) is upgraded to TLS and delivered to the TLS listener channel;
// anything else is delivered plaintext (first byte replayed) to the plain
// channel.
func newSwitchingListener(raw net.Listener, tlsCfg *tls.Config) (plainLis, tlsLis net.Listener, dispatchDone <-chan struct{}) {
	plainCh := make(chan net.Conn, 16)
	tlsCh := make(chan net.Conn, 16)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer close(plainCh)
		defer close(tlsCh)
		for {
			conn, err := raw.Accept()
			if err != nil {
				return
			}
			_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
			buf := make([]byte, 1)
			if _, err := io.ReadFull(conn, buf); err != nil {
				_ = conn.Close()
				continue
			}
			_ = conn.SetReadDeadline(time.Time{})
			if buf[0] == 0x16 && tlsCfg != nil {
				tconn := tls.Server(conn, tlsCfg)
				if err := tconn.Handshake(); err != nil {
					_ = conn.Close()
					continue
				}
				select {
				case tlsCh <- tconn:
				case <-done:
					_ = conn.Close()
					return
				}
			} else {
				select {
				case plainCh <- &replayConn{Conn: conn, first: buf[0]}:
				case <-done:
					_ = conn.Close()
					return
				}
			}
		}
	}()
	addr := raw.Addr()
	plainLis = &chanListener{ch: plainCh, addr: addr}
	tlsLis = &chanListener{ch: tlsCh, addr: addr}
	return plainLis, tlsLis, done
}
