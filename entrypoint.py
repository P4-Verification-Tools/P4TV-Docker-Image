#!/usr/bin/env python3
"""P4TV Entrypoint - Runs P4LTL verification and outputs JSON results"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time

def main():
    if len(sys.argv) < 2:
        print(json.dumps({
            "error": "Usage: entrypoint.py <json_payload>",
            "verdict": "error"
        }), file=sys.stderr)
        sys.exit(1)

    try:
        input_data = json.loads(sys.argv[1])
    except json.JSONDecodeError as e:
        print(json.dumps({
            "error": f"Invalid JSON input: {e}",
            "verdict": "error"
        }), file=sys.stderr)
        sys.exit(1)

    files = input_data.get("files", [])
    if len(files) < 2:
        print(json.dumps({
            "error": "P4 and P4LTL files must be provided in JSON payload",
            "verdict": "error"
        }))
        sys.exit(1)

    p4_file = files[0]
    p4ltl_file = files[1]
    timeout = input_data.get("timeout", 300)

    # Validate input files
    if not os.path.isfile(p4_file):
        print(json.dumps({"error": f"P4 file not found: {p4_file}", "verdict": "error"}))
        sys.exit(1)

    if not os.path.isfile(p4ltl_file):
        print(json.dumps({"error": f"P4LTL file not found: {p4ltl_file}", "verdict": "error"}))
        sys.exit(1)

    # Create temp directory for working files
    with tempfile.TemporaryDirectory() as work_dir:
        boogie_file = os.path.join(work_dir, "p4ltl_boogie.bpl")
        
        start_time = time.time()

        # Step 1: Translate P4 + P4LTL to Boogie
        try:
            translate_result = subprocess.run(
                ["/p4tv/bin/p4c-translator", p4_file, "--ua2", "--p4ltl", p4ltl_file, "-o", boogie_file],
                capture_output=True,
                text=True,
                timeout=30
            )
            translate_output = translate_result.stdout + translate_result.stderr
        except subprocess.TimeoutExpired:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "timeout", "time_ms": elapsed_ms, "details": "Translation P4 + P4LTL to Boogie timeout"}))
            sys.exit(0)
        except Exception as e:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({"verdict": "error", "time_ms": elapsed_ms, "details": f"Translation error: {e}"}))
            sys.exit(1)

        if translate_result.returncode != 0 or not os.path.isfile(boogie_file):
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({
                "verdict": "error",
                "time_ms": elapsed_ms,
                "details": f"Translation failed: {translate_output}"
            }))
            sys.exit(1)

        # Step 2: Run Ultimate Automizer verification
        os.chdir("/p4tv/validator")
        try:
            verify_result = subprocess.run(
                ["/p4tv/validator/P4LTL.sh", boogie_file],
                capture_output=True,
                text=True,
                timeout=timeout
            )
            verify_output = verify_result.stdout + verify_result.stderr
            timed_out = False
        except subprocess.TimeoutExpired:
            elapsed_ms = int((time.time() - start_time) * 1000)
            print(json.dumps({
                "verdict": "timeout",
                "time_ms": elapsed_ms,
                "details": f"Verification timeout after {timeout}s"
            }))
            sys.exit(0)

        elapsed_ms = int((time.time() - start_time) * 1000)

        # Parse verdict (patterns from Ultimate.py)
        # Check for errors FIRST (before true/false)
        if re.search(r"TypeErrorResult|SyntaxErrorResult|could not prove|ExceptionOrErrorResult|UnsupportedSyntaxResult", verify_output, re.IGNORECASE):
            verdict = "error"
        elif re.search(r"AllSpecificationsHoldResult|LTLPropertyHoldsResult|Termination proven", verify_output, re.IGNORECASE):
            verdict = "true"
        elif re.search(r"CounterExampleResult|LTLPropertyNotHoldResult", verify_output, re.IGNORECASE):
            verdict = "false"
        elif timed_out:
            verdict = "timeout"
        else:
            verdict = "unknown"

        # Extract counterexample if present
        counterexample = None
        if verdict == "false":
            # Look for the lasso trace format (Stem/Loop sections)
            # This captures the actual execution trace which shows concrete steps
            lasso_match = re.search(
                r"(Stem:|We found a lasso-shaped).*?(End of lasso representation\.?|RESULT:)",
                verify_output,
                re.DOTALL
            )
            if lasso_match:
                raw_trace = lasso_match.group(0)
                # Clean up the trace to show only the relevant execution steps
                # Extract lines that look like trace statements: [Lxxx] TYPE statement
                trace_lines = []
                current_section = None
                for line in raw_trace.split("\n"):
                    line = line.strip()
                    if line == "Stem:" or line.startswith("Stem: "):
                        if current_section != "Stem":
                            current_section = "Stem"
                            trace_lines.append("=== STEM (initial path) ===")
                    elif line == "Loop:" or line.startswith("Loop: "):
                        if current_section != "Loop":
                            current_section = "Loop"
                            trace_lines.append("=== LOOP (repeating path) ===")
                    elif re.match(r"\[L\d+\]", line):
                        # This is an actual trace statement
                        trace_lines.append(line)
                    elif "End of lasso representation" in line:
                        break
                
                if trace_lines:
                    counterexample = "\n".join(trace_lines)
                else:
                    # Fallback: just use the raw trace (truncated)
                    counterexample = raw_trace[:5000]

        # Build result
        result = {
            "verdict": verdict,
            "time_ms": elapsed_ms,
            "details": verify_output
        }
        if counterexample:
            result["counterexample"] = counterexample

        print(json.dumps(result))

if __name__ == "__main__":
    main()
