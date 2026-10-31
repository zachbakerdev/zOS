# zOS Printer Library Specification

`require("printer")` prints text across as many pages as it needs on an attached printer.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Methods

| Method                        | Returns                                        |
| ----------------------------- | ---------------------------------------------- |
| `printer.available()`         | Whether a printer is attached                  |
| `printer.print(title, text)`  | True, or nil and a message for the user        |

If several printers are attached, the first one found is used.

## Layout

A page holds 21 lines of 25 characters. Printers report their page size only after a page has started, which is too late to count the pages, so this size is fixed.

- Lines wrap with `ui.wrap`, so a word longer than a line, such as a hex key, is cut at the edge of the page.
- A blank line separates sections. A section stays on one page if it fits on one, so that a label doesn't end up on a different page from its value.
- A document with more than one page has `<number>/<total>` added to the title of each page.

## Failures

`print` needs a page of paper and a unit of ink for each page, and checks for them first, so that a document doesn't stop halfway because of them. It can still stop partway if the output tray fills up, and then says how many pages were finished. Printing again starts from the first page.
