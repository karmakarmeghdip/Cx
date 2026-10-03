#!/usr/bin/env bash
# editors/kakoune/test_session.sh — Test Kakoune and kak-lsp integration for Cx
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${REPO_ROOT}/bin:${PATH}"

echo "=========================================================="
echo "Testing Kakoune & kak-lsp editor integration for Cx"
echo "=========================================================="

# 1. Verify required executables
echo -n "[1/5] Checking kak and kak-lsp binaries... "
command -v kak >/dev/null || { echo "FAIL: kak not found in PATH"; exit 1; }
command -v kak-lsp >/dev/null || { echo "FAIL: kak-lsp not found in PATH"; exit 1; }
command -v luajit >/dev/null || { echo "FAIL: luajit not found in PATH"; exit 1; }
echo "OK ($(kak -version), kak-lsp $(kak-lsp --version))"

# 2. Verify cx-lsp script launcher
echo -n "[2/5] Checking cx-lsp server launcher... "
RESP="$(printf 'Content-Length: 48\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"shutdown"}' | "${REPO_ROOT}/bin/cx-lsp" 2>&1 || true)"
if echo "$RESP" | grep -q "listening on stdio"; then
    echo "OK (server boots and listens on stdio)"
else
    echo "FAIL: unexpected cx-lsp response: $RESP"
    exit 1
fi

# 3. Verify cx.kak loading and filetype detection
echo -n "[3/5] Checking cx.kak filetype detection... "
TMP_LOG="$(mktemp)"
kak -ui dummy -n -e '
source editors/kakoune/cx.kak
edit samples/programs/01_hello_args.cx
evaluate-commands %sh{
    if [ "$kak_opt_filetype" != "cx" ]; then
        echo "FAIL: filetype=$kak_opt_filetype" >> "'"$TMP_LOG"'"
    else
        echo "OK" >> "'"$TMP_LOG"'"
    fi
}
quit!
'
if grep -q "OK" "$TMP_LOG"; then
    echo "OK (filetype=cx)"
else
    cat "$TMP_LOG"
    rm -f "$TMP_LOG"
    exit 1
fi
rm -f "$TMP_LOG"

# 4. Verify cx-lsp.kak configuration with kak-lsp
echo -n "[4/5] Checking kak-lsp server registration... "
TMP_LOG="$(mktemp)"
kak -ui dummy -n -e '
source editors/kakoune/kakrc
edit samples/programs/01_hello_args.cx
evaluate-commands %sh{
    printf "%s\n" "$kak_opt_lsp_servers" > "'"$TMP_LOG"'"
}
quit!
'
if grep -q "\[cx-lsp\]" "$TMP_LOG" && grep -q 'command = "cx-lsp"' "$TMP_LOG"; then
    echo "OK (registered cx-lsp server in kakoune-lsp)"
else
    echo "FAIL: lsp_servers not configured properly:"
    cat "$TMP_LOG"
    rm -f "$TMP_LOG"
    exit 1
fi
rm -f "$TMP_LOG"

# 5. Verify highlighters load into Kakoune shared scope
echo -n "[5/5] Checking syntax highlighters and module loading... "
TMP_LOG="$(mktemp)"
kak -ui dummy -e '
try %{
    source editors/kakoune/kakrc
    require-module cx
    evaluate-commands %sh{
        echo "OK" > "'"$TMP_LOG"'"
    }
} catch %{
    evaluate-commands %sh{
        printf "FAIL: %s\n" "$kak_error" > "'"$TMP_LOG"'"
    }
}
quit!
'
if grep -q "^OK" "$TMP_LOG"; then
    echo "OK (cx module and highlighters registered)"
else
    cat "$TMP_LOG"
    rm -f "$TMP_LOG"
    exit 1
fi
rm -f "$TMP_LOG"

echo "=========================================================="
echo "All Kakoune editor integration tests passed successfully!"
echo "=========================================================="
