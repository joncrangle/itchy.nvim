console.log("Hello from TypeScript");

// Runtime error
function divide(x: number, y: number): number {
	if (y === 0) throw new Error("Cannot divide by zero");
	return x / y;
}

try {
	divide(1, 0);
} catch (e) {
	console.error("Error:", e.message);
}

// Async test
async function asyncTest() {
	await new Promise((resolve) => setTimeout(resolve, 1000));
	console.log("Async operation complete");
	try {
		divide(1, 0);
	} catch (e) {
		console.error("Async error:", e.message);
	}
}
asyncTest();

// File read error
try {
	const fs = await import("fs");
	fs.readFileSync("non_existent_file.txt", "utf-8");
} catch (e) {
	console.error("File error:", e.message);
}
