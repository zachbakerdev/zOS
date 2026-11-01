# zOS UI Library Specification

`require("ui")` is the terminal toolkit used by system screens and apps: screens, wrapped text, prompts, menus and a pager.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Theme

`ui.theme` holds the colours to draw with. Apps SHOULD use them rather than naming colours, because they fall back to black and white on computers without colour.

| Field               | Used for                     |
| ------------------- | ---------------------------- |
| `bg`, `fg`          | Normal text                  |
| `dim`               | Hints and less important text |
| `accent`            | Prompts and questions        |
| `good`, `bad`       | Success and failure          |
| `barBg`, `barFg`    | The title bar                |
| `selectBg`, `selectFg` | The selected menu item    |

## Layout

Every screen has a title bar on line 1, and its content starts at column 2 of line 3. Pocket computers are only 26 characters wide, so nothing here may assume a wide screen.

## Drawing

| Method                        | Returns                                                       |
| ----------------------------- | ------------------------------------------------------------- |
| `ui.screen(title, status)`    | Nothing. Clears the screen, draws the title bar and moves to where text starts |
| `ui.text(text, color)`        | Nothing. Writes wrapped text and moves to the next line       |
| `ui.at(x, y, text, fg, bg)`   | Nothing. Writes text at a position, in the default colours if none are given |
| `ui.wrap(text, width)`        | The text as a list of lines of at most `width` characters     |

`status` is text for the right of the title bar, or a function that returns it. It's dropped if the title bar would be too narrow for it. `ui.text` scrolls the screen once it reaches the bottom.

`ui.wrap` breaks at spaces where it can and cuts a word that's too long for a line. `\n` starts a new line, so a blank line in the text stays blank.

## Asking the user

| Method                            | Returns                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| `ui.input(label, mask, default)`  | The line that was typed, or `""`                            |
| `ui.field(label, mask, default)`  | As for `ui.input`, with `label:` on its own line above a `>` |
| `ui.waitEnter(prompt)`            | Nothing. Waits for Enter                                    |
| `ui.message(title, text, color)`  | Nothing. Shows text on its own screen until Enter is pressed |
| `ui.confirm(question)`            | True for Y, and false for N or Backspace                    |

`mask` is the character to show instead of what's typed, for passwords. A short `label` goes in front of the input on the same line, and a long one goes on the line above it.

## Menus

`ui.menu(options)` shows a scrolling list and returns the index of the chosen item.

| Option     | Meaning                                                             |
| ---------- | ------------------------------------------------------------------- |
| `title`    | The title bar's text                                                |
| `status`   | As for `ui.screen`                                                  |
| `items`    | A list of `{ label, hint, fg }`. `hint` is shown at the bottom of the screen while the item is selected, and `fg` colours its label |
| `selected` | The item selected at first. Defaults to 1                           |
| `back`     | Whether Backspace goes back, which returns nil                      |

The arrow keys wrap around. Page Up, Page Down, Home, End, the scroll wheel and clicks also work, and a click chooses the item straight away. Without `back`, the only way out is to choose an item, so the caller MUST offer one that leaves if it's needed. `items` MUST NOT be empty.

```lua
local choice = ui.menu({
    title = "Notes",
    back = true,
    items = { { label = "New note", hint = "Start a blank note" }, { label = "Open a note" } },
})
```

## The pager

`ui.pager(title, text, footer, actions)` shows long text for reading. The arrow keys, Page Up, Page Down and the scroll wheel move through it, and Q or Backspace returns nil.

`footer` replaces the `Q: back` shown at the bottom. `actions` maps lowercase characters to values, and pressing one returns its value. An action can use `q`, which replaces going back, but Backspace always goes back.

```lua
local action = ui.pager("Message", text, "R: reply  Q: back", { r = "reply" })
```

## Events

Menus, prompts and the pager wait with `os.pullEvent`, so Ctrl+T stops an app that's in one of them. They ignore events they aren't looking for, and those are lost. An app that needs events during a menu SHOULD use a service, or draw its own screen.
