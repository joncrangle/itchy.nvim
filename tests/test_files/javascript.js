console.log("Hello from JavaScript");

// Runtime error
function divide(x, y) {
	if (y === 0) throw new Error("Cannot divide by zero");
	return x / y;
}

try {
	divide(1, 0);
} catch (e) {
	console.error("Error:", e?.message ?? e);
}

async function main() {
	await new Promise((resolve) => setTimeout(resolve, 1000));
	console.log("Async operation complete");
	try {
		divide(1, 0);
	} catch (e) {
		console.error("Async error:", e?.message ?? e);
	}
}

main();

// File read error
try {
	const fs = await import("node:fs");
	fs.readFileSync("non_existent_file.txt", "utf8");
} catch (e) {
	console.error("File error:", e?.message ?? e);
}
