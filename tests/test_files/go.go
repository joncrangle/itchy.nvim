package main

import (
	"fmt"
	"log"
	"os"
	"sync"
	"time"
)

func divide(x, y int) int {
	return x / y
}

func main() {
	// Standard output
	fmt.Println("Hello from Go")
	fmt.Printf("Formatted number: %d\n", 42)

	// Logging
	log.Println("This is a log message")

	// Async operation
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(100 * time.Millisecond)
		fmt.Println("Async operation complete")
	}()

	wg.Wait()

	// File read error
	_, err := os.ReadFile("non_existent_file.txt")
	if err != nil {
		log.Println("File error:", err)
	}

	// Divide by zero
	result := divide(10, 0)
	fmt.Println("Result of division:", result)
}
