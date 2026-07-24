#!/usr/bin/env bash
# fixture: the documented heredoc form -- compile a program held in a
# heredoc and eval it in the current shell.  usage: heredoc_form.sh ROOT
source "$1/goto.sh" --lib
eval "$(goto_compile <<'EOF'
echo in heredoc
goto fin
echo no
label fin
echo heredoc done
EOF
)"
echo 'back in the outer script'
