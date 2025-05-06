import asyncio

print("Hello from Python")


# Runtime error test (ZeroDivisionError)
def risky_divide(x, y):
    return x / y


def test_runtime_error():
    try:
        risky_divide(1, 0)
    except ZeroDivisionError as e:
        print("Caught runtime error:", e)


# Async test with error handling
async def async_task():
    await asyncio.sleep(1)
    print("Async operation complete")
    try:
        risky_divide(1, 0)
    except ZeroDivisionError as e:
        print("Caught async error:", e)


# File error test (non-existent file)
def test_file_error():
    try:
        with open("non_existent_file.txt") as f:
            print(f.read())
    except FileNotFoundError as e:
        print("Caught file error:", e)


# Run all tests
async def main():
    test_runtime_error()
    test_file_error()
    await async_task()


asyncio.run(main())
