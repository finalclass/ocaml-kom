Independent state in one session, with quit ignoring subsequent input:

  $ printf 'add a 3\nadd a 2\nshow b\nshow a\nquit\nadd a 100\n' | ../examples/counter/console.exe
  3
  5
  0
  5

Invalid commands leave the state intact and allow subsequent commands:

  $ printf 'add a 3\nadd a nope\nadd c 2\nunknown\nshow a\nadd b -2\nshow b\n' | ../examples/counter/console.exe 2>&1
  3
  Error: Invalid amount: expected an integer
  Error: Unknown counter: expected a or b
  Error: Expected: add <a|b> <integer>, show <a|b>, or quit
  3
  -2
  -2

EOF closes the session and the next process starts from zero:

  $ printf 'show a\nshow b\n' | ../examples/counter/console.exe
  0
  0
  $ ../examples/counter/console.exe < /dev/null
