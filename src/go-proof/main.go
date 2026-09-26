// muslin-go proves a fully static Go binary can ship in the initramfs.
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Printf("muslin-go: %s/%s %s\n", runtime.GOOS, runtime.GOARCH, runtime.Version())
}
