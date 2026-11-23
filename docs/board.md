# Board: the note's tasks as columns in Obsidian

The board button in TaskRadarBar opens a board note in Obsidian. The app does not draw a board itself and creates nothing in your vault: the board is an ordinary note whose [Tasks](https://publish.obsidian.md/tasks/) queries are laid out as columns by a small CSS snippet. The tasks are not copied, so ticking a checkbox on the board edits the task note.

## 1. Tasks plugin

Install and enable the **Tasks** community plugin (Settings → Community plugins).

## 2. CSS snippet

Save this as `radar-board.css` in the snippets folder of the vault (Settings → Appearance → CSS snippets → folder icon), then reload the list and switch the snippet on.

```css
/* A note with `cssclasses: radar-board`: the outer callout [!board] holds the columns [!col|colour]. */
.radar-board {
  --file-line-width: 100%;
}

.radar-board .callout[data-callout="board"] {
  padding: 0;
  border: 0;
  background: transparent;
  box-shadow: none;
}
.radar-board .callout[data-callout="board"] > .callout-title {
  display: none;
}
.radar-board .callout[data-callout="board"] > .callout-content {
  display: flex;
  gap: 12px;
  align-items: flex-start;
  overflow-x: auto;
  padding: 0 0 8px;
}

.radar-board .callout[data-callout="col"] {
  --callout-icon: lucide-list-todo;
  --callout-color: var(--color-blue-rgb);
  flex: 0 0 320px;
  margin: 0;
  max-height: 78vh;
  overflow-y: auto;
}
.radar-board .callout[data-callout="col"] .callout-content > :first-child {
  margin-top: 0;
}

.radar-board .callout[data-callout-metadata="red"]    { --callout-color: var(--color-red-rgb); }
.radar-board .callout[data-callout-metadata="orange"] { --callout-color: var(--color-orange-rgb); }
.radar-board .callout[data-callout-metadata="purple"] { --callout-color: var(--color-purple-rgb); }
.radar-board .callout[data-callout-metadata="gray"]   { --callout-color: 140, 140, 140; }
.radar-board .callout[data-callout-metadata="green"]  { --callout-color: var(--color-green-rgb); }
```

## 3. Board note

Create a note, for example `Board.md`, with the text below. Replace `My tasks` in the `path includes` lines with the name of your task note; without that line the columns show tasks from the whole vault. Open the note in reading view or live preview.

```markdown
---
cssclasses:
  - radar-board
---
> [!board]
> > [!col|red] Overdue
> > ```tasks
> > not done
> > path includes My tasks
> > due before today
> > short mode
> > ```
>
> > [!col|orange] Today
> > ```tasks
> > not done
> > path includes My tasks
> > due on today
> > short mode
> > ```
>
> > [!col] Tomorrow
> > ```tasks
> > not done
> > path includes My tasks
> > due on tomorrow
> > short mode
> > ```
>
> > [!col] This week
> > ```tasks
> > not done
> > path includes My tasks
> > due after tomorrow
> > due on or before next week
> > short mode
> > ```
>
> > [!col] Later
> > ```tasks
> > not done
> > path includes My tasks
> > due after next week
> > short mode
> > ```
>
> > [!col|gray] No due date
> > ```tasks
> > not done
> > path includes My tasks
> > no due date
> > short mode
> > ```
```

Columns are yours to change: any Tasks query works, and the colour after `col|` is one of `red`, `orange`, `purple`, `gray`, `green` (none = blue).

## 4. Tell the app where the board is

Either of:

- Link the board at the top of the task note, before the first `##` heading: for example `Board: [[Board]]`. The app takes the first `[[wikilink]]` it finds there; the words around it do not matter.
- Menu bar icon → gear → "Choose board note…". A chosen note wins over the link. It has to be in the same vault as the task note.

Until one of the two is set, the board button shows these steps instead of opening Obsidian.
