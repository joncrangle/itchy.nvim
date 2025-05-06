#!/bin/bash

echo "Hello from Bash"

# Runtime error
divide() {
  echo $(($1 / $2))
}

# Async simulation
sleep 1 &
wait
printf "Async operation complete"

divide 1 0 || echo "Error: division by zero"
