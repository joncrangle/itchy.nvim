console.log("Hello from JavaScript");

// Runtime error
function divide(x, y) {
	return x / y;
}

try {
	divide(1, 0);
} catch (e) {
	console.error("Error:", e);
}

async function main() {
	await new Promise((resolve) => setTimeout(resolve, 1000));
	console.log("Async operation complete");
	try {
		divide(1, 0);
	} catch (e) {
		console.error("Async error:", e);
	}
}

main();

const fs = require("fs");
fs.readFile("non_existent_file.txt", "utf8", (err, data) => {
	if (err) console.error("File error:", err);
});
