Output assets/demo.gif
Set FontSize 20
Set Width 1300
Set Height 650
Set Theme "Catppuccin Mocha"
Set TypingSpeed 250ms
Set FontFamily "DejaVuSansM Nerd Font"

Hide
Type "nvim tests/test_files/python.py"
Enter
Type ":set laststatus=0"
Enter
Sleep 2
Show

Type ":Itchy run"
Enter
Sleep 4
Screenshot assets/itchy.png

Space
Type "."
Sleep 2
Enter
Sleep 4
Screenshot assets/itchy-snacks.png

Hide
Type "q"
Enter
Type ":q"
Enter
