// muslin-go proves a fully static Go binary can ship in the initramfs.
package main

import (
	"fmt"
	"os"
	"runtime"
	"syscall"
)

const statusPage = "HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 31\r\nConnection: close\r\n\r\nMuslin Linux: networking works\n"

func serve() error {
	listener, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(listener)

	if err := syscall.SetsockoptInt(listener, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1); err != nil {
		return err
	}
	address := &syscall.SockaddrInet4{Port: 80}
	if err := syscall.Bind(listener, address); err != nil {
		return err
	}
	if err := syscall.Listen(listener, 8); err != nil {
		return err
	}

	fmt.Println("muslin-http: listening on :80")
	for {
		connection, _, err := syscall.Accept(listener)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			return err
		}
		var request [1024]byte
		_, _ = syscall.Read(connection, request[:])
		_, _ = syscall.Write(connection, []byte(statusPage))
		_ = syscall.Close(connection)
	}
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "serve" {
		if err := serve(); err != nil {
			fmt.Fprintf(os.Stderr, "muslin-http: %v\n", err)
			os.Exit(1)
		}
		return
	}
	fmt.Printf("muslin-go: %s/%s %s\n", runtime.GOOS, runtime.GOARCH, runtime.Version())
}
