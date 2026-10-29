# zOS Calculator

A calculator app for [zOS](../../README.md). Type an expression and press Enter; an empty line quits.

```
2^10                 = 1024
sqrt(2) * pi         = 4.442882938
x = 5 * 3            = 15
floor(ans / 4)       = 3
```

- Every function in Lua's `math` library is available without the `math.` prefix (`sin`,
  `floor`, `max`, ...), plus `pi`, `huge` and `ln` (natural log).
- `name = expression` stores a variable. `ans` is the last result.
- Expressions run in a sandbox that only contains those functions and your variables.

## Installing

Copy the `calc/` folder onto a floppy disk, put it in a drive next to the zOS computer, and
install it with the **App Manager** app or from the Shell:

```
appman install disk/calc
```

Since the Calculator is a single file, you can also upload `calc/main.lua` to Pastebin and run
`appman get <code> calc`.
