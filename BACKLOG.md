# TaskRadarBar backlog

## Not in the first version

- [ ] Global hotkey to open the window.
- [ ] Creating new tasks from the app.
- [ ] Tasks from other files of the vault. The app reads and edits one chosen note, although in Obsidian a query without a tag filter pulls tasks from the whole vault.

## Ideas

- [ ] An Obsidian plugin version.
- [ ] A reminder about everything in a chosen filter at a set time of day, for example "Today" at 9:00. Done so far: reminders before meetings, for blocks with a time in their bold label.

## Known simplifications in the code (marked `ponytail:`)

- [ ] Status types are hardcoded (`x` done, `-` cancelled), not read from the Tasks plugin settings.
- [ ] Only the Tasks query filters listed in `atom` (`Sources/Core.swift`) are supported; a section with an unknown line shows an error.
- [ ] The task type tags `#mod/radar`, `/ask`, `/wait` are hardcoded, not configurable.
- [ ] File changes are detected by polling every 3 seconds.
- [ ] Reminders are kept by macOS and keyed by the task text; editing the text drops the reminder.
- [ ] Recurrence: the app understands only `every [N] day|week|month|year`, `every weekday` and `when done`; tasks with other rules (`every month on the 15th`) have to be completed in Obsidian.
- [ ] The board note is the first wikilink at the top of the task note and is not checked for existence; a board chosen in settings must be in the same vault and can be replaced but not cleared.
- [ ] Reminders before meetings: the app posts them itself while it runs, nothing is scheduled with macOS, so a reminder missed while the Mac slept is skipped. The time in the block label is taken as today's, and a reminder never crosses midnight. The setting is keyed by the note heading; renaming the heading drops it.
- [ ] The comment draft is stored in the app settings and keyed by the task text; editing the text loses the draft.

## Security (from the audit of 2026-11-23)

- [ ] App Sandbox without the network entitlement: the system would forbid network access, instead of the app merely having no network code. Needs a security-scoped bookmark for the note, and the atomic write and the `.obsidian` folder lookup have to be checked inside the sandbox.
- [ ] Developer ID signing and notarization for the release builds: the signature is ad-hoc now, so Gatekeeper blocks the app on another Mac.
- [ ] The link text in a task can differ from its address (`[google.com](https://another-site)`); the address is not shown before opening.
- [ ] Comment drafts and the note path are stored as plain text in the app settings (`defaults read com.ktar.taskradarbar`); old drafts are never cleaned up.
- [ ] Priority is detected by its emoji anywhere in the line, not only in the trailing metadata.
