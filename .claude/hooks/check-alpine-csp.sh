#!/usr/bin/env bash
# PostToolUse hook: Check Blade files for Alpine.js CSP violations
# This project uses @alpinejs/csp which silently fails on inline expressions.

FILE=$(jq -r '.tool_input.file_path // empty')
[[ -z "$FILE" ]] && exit 0
[[ "$FILE" != *.blade.php ]] && exit 0
[[ ! -f "$FILE" ]] && exit 0

violations=()

# Inline x-data objects: x-data="{ ... }" or x-data="{ ... }"
while IFS= read -r line; do
    violations+=("$line")
done < <(grep -nP 'x-data\s*=\s*"[{]' "$FILE" 2>/dev/null)

# Compound expressions in directives (&&, ||, >, <, ?, .length, !)
while IFS= read -r line; do
    violations+=("$line")
done < <(grep -nP 'x-(show|if|bind:[a-z]+)\s*=\s*"[^"]*(\&\&|\|\||[><!?]|\.length)' "$FILE" 2>/dev/null)

# Parenthesized event handlers: @click="method()" or x-on:click="method()"
while IFS= read -r line; do
    violations+=("$line")
done < <(grep -nP '(@|x-on:)[a-z.]+\s*=\s*"[a-zA-Z]+\(' "$FILE" 2>/dev/null)

if [[ ${#violations[@]} -gt 0 ]]; then
    echo "ALPINE CSP VIOLATION in $FILE:"
    printf '%s\n' "${violations[@]}"
    echo ""
    echo "This project uses @alpinejs/csp — inline expressions silently fail."
    echo "Register components via Alpine.data() and use bare property/method names."
    exit 2
fi
