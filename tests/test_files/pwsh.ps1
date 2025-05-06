Write-Host "Hello from PowerShell"
echo Echo from PowerShell

# Function definition with error handling
function Divide-Numbers {
    param (
        [int]$Numerator,
        [int]$Denominator
    )
    
    try {
        $result = $Numerator / $Denominator
        return $result
    }
    catch [System.DivideByZeroException] {
        Write-Host "Caught division error: Attempted to divide by zero"
        return $null
    }
}

# Async simulation
function Test-Async {
    Write-Host "Starting async operation..."
    Start-Sleep -Seconds 1
    Write-Host "Async operation complete"
    
    try {
        $null = 1/0
    }
    catch {
        Write-Host "Caught async error: $_"
    }
}

# File error test
function Test-FileError {
    try {
        $content = Get-Content -Path "non_existent_file.txt" -ErrorAction Stop
        Write-Host $content
    }
    catch {
        Write-Host "Caught file error: $_"
    }
}

# Main execution
Write-Host "Running division test..."
$result = Divide-Numbers -Numerator 10 -Denominator 2
Write-Host "Result: $result"

Write-Host "Running division by zero test with catch..."
$result = Divide-Numbers -Numerator 1 -Denominator 0
Write-Host "Result: $result"

Write-Host "Running division by zero test..."
$result = 1/0
Write-Host "Result: $result"

Write-Host "Running file error test..."
Test-FileError

Write-Host "Running async test..."
Test-Async

Write-Host "All tests completed"
