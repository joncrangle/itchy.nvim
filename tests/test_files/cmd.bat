echo Hello from CMD

:: Basic error handling
echo Running division test...
set /a result=10/2
echo Result: %result%

:: Error simulation
echo Running division by zero test...
echo This will show an error message:
set /a result=1/0 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo Caught error: Division by zero attempted
)

:: File error test
echo Running file error test...
if not exist non_existent_file.txt (
    echo Caught file error: The system cannot find the file specified
) else (
    type non_existent_file.txt
)

:: Async simulation using timeout
echo Starting async operation...
timeout /t 1 /nobreak >nul
echo Async operation complete

:: Using external commands
echo Testing external command execution...
where /q python
if %ERRORLEVEL% EQU 0 (
    echo Python is available
) else (
    echo Python is not available
)

:: Loop example
echo Demonstrating loop:
for %%i in (1 2 3) do (
    echo Loop iteration: %%i
)

echo All tests completed
