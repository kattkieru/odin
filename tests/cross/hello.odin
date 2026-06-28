package cross_link_regression

import "core:fmt"

// Minimal program used by the native-link regression guardrail.
// It exists only so that the regression script has a small, stable
// thing to compile and link natively; its output is not important.
main :: proc() {
	fmt.println("hello from the native-link regression smoke test")
}
