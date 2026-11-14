#!/bin/sh
# Run the tests against this checkout.  Needs `guix'; changes nothing
# outside a temporary directory.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
python3 -m py_compile "$here/guix-manager" 2>/dev/null || python3 -c "
import ast, sys; ast.parse(open(sys.argv[1]).read())" "$here/guix-manager"
XDG_CONFIG_HOME="$tmp" guix repl -L "$here/extensions" -- "$here/tests/edit.scm"
