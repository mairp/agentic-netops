// Package redisx is a minimal, dependency-free Redis RESP2 client sufficient
// for the AINETOPS device daemons (SONiC redis with per-DB SELECT).
package redisx

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Client is a single-connection RESP2 client.
type Client struct {
	conn net.Conn
	r    *bufio.Reader
}

// New dials addr and returns a client.
func New(addr string) (*Client, error) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	return &Client{conn: conn, r: bufio.NewReader(conn)}, nil
}

// Close closes the connection.
func (c *Client) Close() error { return c.conn.Close() }

// Cmd issues a command and returns the raw reply.
func (c *Client) Cmd(args ...string) (any, error) {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("*%d\r\n", len(args)))
	for _, a := range args {
		sb.WriteString(fmt.Sprintf("$%d\r\n%s\r\n", len(a), a))
	}
	if _, err := c.conn.Write([]byte(sb.String())); err != nil {
		return nil, err
	}
	return c.readReply()
}

func (c *Client) readReply() (any, error) {
	line, err := c.r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	if line == "" {
		return nil, errors.New("redisx: empty reply line")
	}
	switch line[0] {
	case '+':
		return line[1:], nil
	case '-':
		return nil, errors.New(line[1:])
	case ':':
		n, err := strconv.ParseInt(line[1:], 10, 64)
		if err != nil {
			return nil, err
		}
		return n, nil
	case '$':
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		buf := make([]byte, n+2)
		if _, err := ioReadFull(c.r, buf); err != nil {
			return nil, err
		}
		return string(buf[:n]), nil
	case '*':
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		out := make([]any, 0, n)
		for i := 0; i < n; i++ {
			v, err := c.readReply()
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("redisx: unknown reply prefix %q", line[0])
	}
}

func ioReadFull(r *bufio.Reader, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := r.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// String converts a reply to string (nil -> "").
func String(v any) string {
	s, _ := v.(string)
	return s
}

// Select switches to the given database number.
func (c *Client) Select(db int) error {
	_, err := c.Cmd("SELECT", strconv.Itoa(db))
	return err
}

// HGetAll returns all fields of a hash (nil map if key absent).
func (c *Client) HGetAll(key string) (map[string]string, error) {
	v, err := c.Cmd("HGETALL", key)
	if err != nil {
		return nil, err
	}
	list, ok := v.([]any)
	if !ok || len(list) == 0 {
		return nil, nil
	}
	out := make(map[string]string, len(list)/2)
	for i := 0; i+1 < len(list); i += 2 {
		out[String(list[i])] = String(list[i+1])
	}
	return out, nil
}

// HSet sets hash fields.
func (c *Client) HSet(key string, kv map[string]string) error {
	args := []string{"HSET", key}
	for k, v := range kv {
		args = append(args, k, v)
	}
	_, err := c.Cmd(args...)
	return err
}

// HDel deletes hash fields.
func (c *Client) HDel(key string, fields ...string) error {
	args := append([]string{"HDEL", key}, fields...)
	_, err := c.Cmd(args...)
	return err
}

// Del deletes keys.
func (c *Client) Del(keys ...string) error {
	args := append([]string{"DEL"}, keys...)
	_, err := c.Cmd(args...)
	return err
}

// Keys returns keys matching the pattern (fine for lab-scale DBs).
func (c *Client) Keys(pattern string) ([]string, error) {
	v, err := c.Cmd("KEYS", pattern)
	if err != nil {
		return nil, err
	}
	list, ok := v.([]any)
	if !ok {
		return nil, nil
	}
	out := make([]string, 0, len(list))
	for _, e := range list {
		out = append(out, String(e))
	}
	return out, nil
}

// TableKeys returns the list of keys under a table prefix "TABLE|".
func (c *Client) TableKeys(table string) ([]string, error) {
	return c.Keys(table + "|*")
}
